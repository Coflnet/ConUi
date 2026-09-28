import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/backup/backup_exceptions.dart';
import 'package:relationship_manager/backup/backup_format.dart';
import 'package:relationship_manager/backup/backup_progress.dart';
import 'package:relationship_manager/backup/backup_writer.dart';
import 'package:relationship_manager/services/wav.dart';

import 'fakes.dart';

void main() {
  group('BackupWriter', () {
    test('writes manifest.json, data.json, README.txt and every recording', () async {
      final wav = buildTestWav(1000, seed: 1);
      final source = FakeBackupDataSource(
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
      final result = await BackupWriter().write(source: source, output: output);

      final archive = ZipDecoder().decodeBytes(output.getBytes());
      expect(archive.findFile('manifest.json'), isNotNull);
      expect(archive.findFile('data.json'), isNotNull);
      expect(archive.findFile('README.txt'), isNotNull);
      expect(archive.findFile('recordings/rec1.wav'), isNotNull);
      expect(archive.findFile('recordings/rec1.wav')!.readBytes(), wav);

      expect(result.manifest.formatVersion, currentBackupFormatVersion);
      expect(result.manifest.counts['persons'], 1);
      expect(result.manifest.counts['events'], 1);
      expect(result.manifest.recordings, hasLength(1));
      expect(result.manifest.recordings.single.id, 'rec1');
      expect(result.manifest.recordings.single.sizeBytes, wav.length);
      expect(result.manifest.recordings.single.sha256Hex, sha256Of(wav));
      expect(result.manifest.missingAudio, isEmpty);
    });

    test('stores recordings without compression (CompressionType.store)', () async {
      // Highly compressible PCM (all zero) still shows up uncompressed in
      // the zip's central directory, proving "store" mode is actually used
      // rather than deflate defaulting in.
      final wav = buildTestWav(0, seed: 0); // header only, but same code path
      final compressibleWav =
          _wavWithZeros(50000); // 50,000 zero bytes of PCM: compresses hugely under deflate
      final source = FakeBackupDataSource(recordingsOnDevice: {
        'rec1': wav,
        'rec2': compressibleWav,
      });

      final output = OutputMemoryStream();
      await BackupWriter().write(source: source, output: output);
      final archive = ZipDecoder().decodeBytes(output.getBytes());
      final entry = archive.findFile('recordings/rec2.wav')!;
      expect(entry.compression, CompressionType.none);
    });

    test('a story\'s recording missing from the device is reported as missingAudio '
        'and not included as a recording entry', () async {
      final source = FakeBackupDataSource(
        tables: {
          'events': [
            makeRecord('events', 'e1', data: {
              'title': 'A story',
              'files': [recordingFileJson('missing-rec')],
            }),
          ],
        },
        recordingsOnDevice: {}, // the recording's bytes are gone
      );

      final output = OutputMemoryStream();
      final result = await BackupWriter().write(source: source, output: output);

      expect(result.manifest.missingAudio, ['missing-rec']);
      expect(result.manifest.recordings, isEmpty);
    });

    test('backs up a recording on device even if no story references it '
        '(an orphaned/in-progress recording must not be silently dropped)', () async {
      final wav = buildTestWav(500, seed: 3);
      final source = FakeBackupDataSource(recordingsOnDevice: {'orphan': wav});

      final output = OutputMemoryStream();
      final result = await BackupWriter().write(source: source, output: output);

      expect(result.manifest.recordings.map((r) => r.id), ['orphan']);
      expect(result.manifest.missingAudio, isEmpty);
    });

    test('includes soft-deleted entities in data.json', () async {
      final source = FakeBackupDataSource(tables: {
        'persons': [
          makeRecord('persons', 'p1', data: {'name': 'Ada'}, isDeleted: true),
        ],
      });

      final output = OutputMemoryStream();
      await BackupWriter().write(source: source, output: output);

      final archive = ZipDecoder().decodeBytes(output.getBytes());
      final dataJson =
          jsonDecode(utf8.decode(archive.findFile('data.json')!.readBytes()!)) as Map;
      final persons = dataJson['persons'] as List;
      expect(persons, hasLength(1));
      expect((persons.single as Map)['isDeleted'], true);
    });

    test('README.txt explains the archive in English and German', () async {
      final source = FakeBackupDataSource();
      final output = OutputMemoryStream();
      await BackupWriter().write(source: source, output: output);
      final archive = ZipDecoder().decodeBytes(output.getBytes());
      final readme = utf8.decode(archive.findFile('README.txt')!.readBytes()!);
      expect(readme, contains('ENGLISH'));
      expect(readme, contains('DEUTSCH'));
      expect(readme, contains('manifest.json'));
      expect(readme, contains('recordings/'));
    });

    test('reports progress while writing recordings', () async {
      final source = FakeBackupDataSource(recordingsOnDevice: {
        'a': buildTestWav(10, seed: 1),
        'b': buildTestWav(10, seed: 2),
      });
      final phases = <BackupPhase>[];
      final output = OutputMemoryStream();
      await BackupWriter().write(
        source: source,
        output: output,
        onProgress: (p) => phases.add(p.phase),
      );
      expect(phases, contains(BackupPhase.collectingData));
      expect(phases, contains(BackupPhase.writingRecordings));
      expect(phases, contains(BackupPhase.writingMetadata));
    });

    test('cancellation raises BackupCancelledException and writes nothing further',
        () async {
      final source = FakeBackupDataSource(recordingsOnDevice: {
        'a': buildTestWav(10, seed: 1),
        'b': buildTestWav(10, seed: 2),
      });
      final output = OutputMemoryStream();
      var calls = 0;
      await expectLater(
        BackupWriter().write(
          source: source,
          output: output,
          isCancelled: () => (++calls) > 1, // cancel partway through
        ),
        throwsA(isA<BackupCancelledException>()),
      );
    });
  });
}

// A WAV file whose PCM payload is all zero bytes - used by the "store, not
// deflate" test above, which needs something that would compress
// dramatically if it were mistakenly deflated, making a regression obvious.
Uint8List _wavWithZeros(int pcmLength) {
  final pcm = Uint8List(pcmLength); // zero-filled by default
  final header = WavHeader.build(dataLength: pcm.length);
  final out = Uint8List(header.length + pcm.length);
  out.setRange(0, header.length, header);
  out.setRange(header.length, out.length, pcm);
  return out;
}
