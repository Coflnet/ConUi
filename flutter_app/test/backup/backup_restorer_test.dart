import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/backup/backup_exceptions.dart';
import 'package:relationship_manager/backup/backup_format.dart';
import 'package:relationship_manager/backup/backup_restorer.dart';
import 'package:relationship_manager/backup/backup_source.dart';
import 'package:relationship_manager/backup/backup_writer.dart';

import 'fakes.dart';

/// Builds a raw zip archive directly (bypassing BackupWriter), so hostile /
/// malformed-archive tests have full control over what's actually inside -
/// including gaps and contradictions a real backup could never produce.
Uint8List _buildRawArchive({
  Map<String, dynamic>? manifestJson,
  Map<String, dynamic>? dataJson,
  Map<String, Uint8List> recordings = const {},
  bool includeManifest = true,
  bool includeData = true,
}) {
  final archive = Archive();
  if (includeManifest && manifestJson != null) {
    final bytes = utf8.encode(jsonEncode(manifestJson));
    archive.addFile(ArchiveFile.bytes('manifest.json', bytes));
  }
  if (includeData && dataJson != null) {
    final bytes = utf8.encode(jsonEncode(dataJson));
    archive.addFile(ArchiveFile.bytes('data.json', bytes));
  }
  for (final entry in recordings.entries) {
    archive.addFile(
      ArchiveFile.bytes('recordings/${entry.key}.wav', entry.value)
        ..compression = CompressionType.none,
    );
  }
  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}

Map<String, dynamic> _emptyDataJson() =>
    {for (final t in backupEntityTables) t: <dynamic>[]};

Map<String, dynamic> _manifestJson({
  int formatVersion = currentBackupFormatVersion,
  Map<String, int>? counts,
  List<Map<String, dynamic>> recordings = const [],
  List<String> missingAudio = const [],
}) =>
    {
      'formatVersion': formatVersion,
      'createdAt': DateTime(2024, 6, 1).toIso8601String(),
      'appVersion': '1.0.0+1',
      'databaseSchemaVersion': 2,
      'counts': counts ?? {for (final t in backupEntityTables) t: 0},
      'recordings': recordings,
      'missingAudio': missingAudio,
    };

/// A full, valid archive (via the real BackupWriter) with one person, one
/// story referencing one recording. Used as the "happy path" fixture for
/// most tests below.
Future<Uint8List> _validArchive({FakeBackupDataSource? source}) async {
  final wav = buildTestWav(200, seed: 7);
  final src = source ??
      FakeBackupDataSource(
        tables: {
          'persons': [makeRecord('persons', 'p1', data: {'name': 'Ada'})],
          'events': [
            makeRecord('events', 'e1', data: {
              'title': 'A story',
              'files': [recordingFileJson('rec1')],
            }),
          ],
        },
        recordingsOnDevice: {'rec1': wav},
      );
  final output = OutputMemoryStream();
  await BackupWriter().write(source: src, output: output);
  return output.getBytes();
}

void main() {
  group('BackupRestorer.preview', () {
    test('returns the manifest without touching any sink', () async {
      final bytes = await _validArchive();
      final preview = BackupRestorer().preview(InputMemoryStream(bytes));
      expect(preview.manifest.counts['persons'], 1);
      expect(preview.manifest.recordings, hasLength(1));
    });
  });

  group('BackupRestorer.verify', () {
    test('an intact archive has no problems', () async {
      final bytes = await _validArchive();
      expect(BackupRestorer().verify(InputMemoryStream(bytes)), isEmpty);
    });

    test('a tampered recording is reported', () async {
      final wav = buildTestWav(200, seed: 7);
      final archive = ZipDecoder().decodeBytes(await _validArchive());
      // Rebuild the zip with the recording bytes corrupted after the fact,
      // so the manifest's checksum no longer matches.
      final tampered = Uint8List.fromList(wav)..[50] = (wav[50] + 1) % 256;
      final rebuilt = Archive();
      for (final f in archive) {
        if (f.name == 'recordings/rec1.wav') {
          rebuilt.addFile(ArchiveFile.bytes(f.name, tampered)..compression = CompressionType.none);
        } else {
          rebuilt.addFile(ArchiveFile.bytes(f.name, f.readBytes()!));
        }
      }
      final bytes = Uint8List.fromList(ZipEncoder().encodeBytes(rebuilt));
      final problems = BackupRestorer().verify(InputMemoryStream(bytes));
      expect(problems, isNotEmpty);
      expect(problems.first, contains('checksum'));
    });
  });

  group('BackupRestorer.apply - merge rules', () {
    test('a fresh restore adds every entity and recording', () async {
      final bytes = await _validArchive();
      final sink = FakeBackupDataSink();
      final result = await BackupRestorer().apply(InputMemoryStream(bytes), sink);

      expect(result.entities.every((e) => e.outcome == MergeOutcome.added), isTrue);
      expect(result.recordings.single.outcome, RecordingOutcome.restored);
      expect(sink.tables['persons']!['p1'], isNotNull);
      expect(sink.recordings['rec1'], isNotNull);
      expect(sink.storeVerifiedRecordingCalls, 1);
    });

    test('running the same restore twice changes nothing the second time', () async {
      final bytes = await _validArchive();
      final sink = FakeBackupDataSink();
      await BackupRestorer().apply(InputMemoryStream(bytes), sink);

      final second = await BackupRestorer().apply(InputMemoryStream(bytes), sink);

      expect(second.entities.every((e) => e.outcome == MergeOutcome.skipped), isTrue);
      expect(second.recordings.single.outcome, RecordingOutcome.alreadyPresent);
      expect(sink.storeVerifiedRecordingCalls, 1); // still just the first call
      expect(sink.applyEntityRestoreCalls.last, isEmpty); // nothing new to apply
    });

    test('an older updatedAt than what is already local is skipped', () async {
      final sink = FakeBackupDataSink();
      sink.seedEntity(makeRecord('persons', 'p1',
          data: {'name': 'Ada (local, newer)'}, updatedAt: DateTime(2024, 6, 1)));

      final source = FakeBackupDataSource(tables: {
        'persons': [
          makeRecord('persons', 'p1',
              data: {'name': 'Ada (backup, older)'}, updatedAt: DateTime(2024, 1, 1)),
        ],
      });
      final output = OutputMemoryStream();
      await BackupWriter().write(source: source, output: output);

      final result =
          await BackupRestorer().apply(InputMemoryStream(output.getBytes()), sink);

      expect(result.entities.single.outcome, MergeOutcome.skipped);
      expect(sink.tables['persons']!['p1']!.data['name'], 'Ada (local, newer)');
    });

    test('a newer updatedAt than what is already local overwrites it', () async {
      final sink = FakeBackupDataSink();
      sink.seedEntity(makeRecord('persons', 'p1',
          data: {'name': 'Ada (local, older)'}, updatedAt: DateTime(2024, 1, 1)));

      final source = FakeBackupDataSource(tables: {
        'persons': [
          makeRecord('persons', 'p1',
              data: {'name': 'Ada (backup, newer)'}, updatedAt: DateTime(2024, 6, 1)),
        ],
      });
      final output = OutputMemoryStream();
      await BackupWriter().write(source: source, output: output);

      final result =
          await BackupRestorer().apply(InputMemoryStream(output.getBytes()), sink);

      expect(result.entities.single.outcome, MergeOutcome.updated);
      expect(sink.tables['persons']!['p1']!.data['name'], 'Ada (backup, newer)');
    });

    test('recordings are stored before entity data is applied', () async {
      final bytes = await _validArchive();
      final sink = FakeBackupDataSink();
      await BackupRestorer().apply(InputMemoryStream(bytes), sink);
      expect(sink.callOrder, ['recording:rec1', 'entities']);
    });
  });

  group('BackupRestorer.apply - recording conflicts and warnings', () {
    test('a checksum mismatch is reported as a warning and the rest still restores',
        () async {
      final wav = buildTestWav(200, seed: 7);
      final bytes = _buildRawArchive(
        manifestJson: _manifestJson(
          counts: {'persons': 1, 'connections': 0, 'places': 0, 'events': 0, 'objects': 0},
          recordings: [
            {'id': 'rec1', 'size': wav.length, 'sha256': '0' * 64}, // wrong on purpose
          ],
        ),
        dataJson: {
          ..._emptyDataJson(),
          'persons': [makeRecord('persons', 'p1', data: {'name': 'Ada'}).toJson()],
        },
        recordings: {'rec1': wav},
      );

      final sink = FakeBackupDataSink();
      final result = await BackupRestorer().apply(InputMemoryStream(bytes), sink);

      expect(result.recordings.single.outcome, RecordingOutcome.checksumMismatch);
      expect(sink.storeVerifiedRecordingCalls, 0);
      // The rest of the restore still proceeds.
      expect(result.entities.single.outcome, MergeOutcome.added);
      expect(sink.tables['persons']!['p1'], isNotNull);
    });

    test('an existing recording with a different checksum is kept, not overwritten',
        () async {
      final wav = buildTestWav(200, seed: 7);
      final bytes = await _validArchive();
      final sink = FakeBackupDataSink();
      sink.seedChecksumOnly('rec1', 'f' * 64); // pretend a different recording is already there

      final result = await BackupRestorer().apply(InputMemoryStream(bytes), sink);

      expect(result.recordings.single.outcome, RecordingOutcome.conflictKept);
      expect(sink.storeVerifiedRecordingCalls, 0);
      expect(sink.recordings.containsKey('rec1'), isFalse);
      expect(wav, isNotEmpty); // wav constructed only to document what was NOT written
    });

    test('an existing recording with the SAME checksum is left alone (already present)',
        () async {
      final bytes = await _validArchive();
      final wav = buildTestWav(200, seed: 7);
      final sink = FakeBackupDataSink()..seedRecording('rec1', wav);

      final result = await BackupRestorer().apply(InputMemoryStream(bytes), sink);

      expect(result.recordings.single.outcome, RecordingOutcome.alreadyPresent);
      expect(sink.storeVerifiedRecordingCalls, 0);
    });

    test('a path-traversal-shaped recording id is ignored, never looked up or stored',
        () async {
      final bytes = _buildRawArchive(
        manifestJson: _manifestJson(recordings: [
          {'id': '../../etc/passwd', 'size': 4, 'sha256': 'a' * 64},
        ]),
        dataJson: _emptyDataJson(),
      );
      final sink = FakeBackupDataSink();
      final result = await BackupRestorer().apply(InputMemoryStream(bytes), sink);

      expect(result.recordings.single.outcome, RecordingOutcome.invalidId);
      expect(sink.storeVerifiedRecordingCalls, 0);
      expect(sink.recordings, isEmpty);
    });

    test('an absolute-path-shaped recording id is ignored, never looked up or stored',
        () async {
      final bytes = _buildRawArchive(
        manifestJson: _manifestJson(recordings: [
          {'id': '/etc/passwd', 'size': 4, 'sha256': 'a' * 64},
        ]),
        dataJson: _emptyDataJson(),
      );
      final sink = FakeBackupDataSink();
      final result = await BackupRestorer().apply(InputMemoryStream(bytes), sink);

      expect(result.recordings.single.outcome, RecordingOutcome.invalidId);
      expect(sink.storeVerifiedRecordingCalls, 0);
    });
  });

  group('BackupRestorer - refusals', () {
    test('refuses an unknown formatVersion with a clear message', () {
      final bytes = _buildRawArchive(
        manifestJson: _manifestJson(formatVersion: 99),
        dataJson: _emptyDataJson(),
      );
      expect(
        () => BackupRestorer().preview(InputMemoryStream(bytes)),
        throwsA(isA<UnsupportedBackupVersionException>()
            .having((e) => e.foundVersion, 'foundVersion', 99)),
      );
    });

    test('refuses an archive with no manifest.json', () {
      final bytes = _buildRawArchive(dataJson: _emptyDataJson(), includeManifest: false);
      expect(
        () => BackupRestorer().preview(InputMemoryStream(bytes)),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('refuses an archive with no data.json', () {
      final bytes = _buildRawArchive(manifestJson: _manifestJson(), includeData: false);
      expect(
        () => BackupRestorer().preview(InputMemoryStream(bytes)),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('refuses an entry larger than the configured limit', () {
      final bigManifest = _manifestJson();
      final bytes = _buildRawArchive(manifestJson: bigManifest, dataJson: _emptyDataJson());
      final restorer = BackupRestorer(maxManifestBytes: 10); // manifest.json is well over 10 bytes
      expect(
        () => restorer.preview(InputMemoryStream(bytes)),
        throwsA(isA<BackupTooLargeException>()),
      );
    });

    test('refuses an archive with more entries than the configured limit', () {
      final bytes = _buildRawArchive(
        manifestJson: _manifestJson(),
        dataJson: _emptyDataJson(),
        recordings: {
          'r1': Uint8List(4),
          'r2': Uint8List(4),
          'r3': Uint8List(4),
        },
      );
      // manifest.json + data.json + 3 recordings = 5 entries.
      final restorer = BackupRestorer(maxEntryCount: 4);
      expect(
        () => restorer.preview(InputMemoryStream(bytes)),
        throwsA(isA<BackupTooLargeException>()),
      );
    });

    test('refuses when the manifest declares more total recording bytes than the '
        'configured limit', () {
      final bytes = _buildRawArchive(
        manifestJson: _manifestJson(recordings: [
          {'id': 'rec1', 'size': 1000, 'sha256': 'a' * 64},
        ]),
        dataJson: _emptyDataJson(),
      );
      final restorer = BackupRestorer(maxTotalRecordingBytes: 500);
      expect(
        () => restorer.preview(InputMemoryStream(bytes)),
        throwsA(isA<BackupTooLargeException>()),
      );
    });

    test('reports a truncated archive as corrupt rather than crashing', () async {
      final bytes = await _validArchive();
      final truncated = bytes.sublist(0, bytes.length - 200);
      expect(
        () => BackupRestorer().preview(InputMemoryStream(truncated)),
        throwsA(isA<BackupArchiveCorruptException>()),
      );
    });

    test('reports a file that is not a zip at all as corrupt rather than crashing', () {
      final notAZip = Uint8List.fromList(utf8.encode('this is not a zip file'));
      expect(
        () => BackupRestorer().preview(InputMemoryStream(notAZip)),
        throwsA(isA<BackupArchiveCorruptException>()),
      );
    });
  });

  group('BackupRestorer - missing audio passthrough', () {
    test('missingAudio from the manifest is exposed on the result for the UI', () async {
      final bytes = _buildRawArchive(
        manifestJson: _manifestJson(missingAudio: ['gone-1', 'gone-2']),
        dataJson: _emptyDataJson(),
      );
      final sink = FakeBackupDataSink();
      final result = await BackupRestorer().apply(InputMemoryStream(bytes), sink);
      expect(result.manifest.missingAudio, ['gone-1', 'gone-2']);
    });
  });
}
