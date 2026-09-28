import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import '../models/event.dart' show AttachedFile;
import 'backup_entity.dart';
import 'backup_exceptions.dart';
import 'backup_format.dart';
import 'backup_manifest.dart';
import 'backup_progress.dart';
import 'backup_readme.dart';
import 'backup_source.dart';

/// What [BackupWriter.write] produced.
class BackupWriteResult {
  final BackupManifest manifest;
  const BackupWriteResult({required this.manifest});
}

/// Builds a backup archive from a [BackupDataSource] onto an [OutputStream].
///
/// Pure Dart: no Flutter or dart:io imports, so it's exercised directly by
/// fast unit tests. The concrete [OutputStream] is chosen by the caller -
/// an `OutputFileStream` writing straight to a temp file on native
/// (streaming; the archive is never held in memory), or an
/// `OutputMemoryStream` on web (see backup_service.dart for why web can't
/// avoid that). Either way, [write] never holds more than one recording's
/// bytes in memory at a time, and never accumulates previously-written
/// recordings - see the peak-memory regression test in
/// test/backup/backup_writer_memory_test.dart.
class BackupWriter {
  Future<BackupWriteResult> write({
    required BackupDataSource source,
    required OutputStream output,
    DateTime Function() now = DateTime.now,
    BackupCancelCheck? isCancelled,
    BackupProgressCallback? onProgress,
  }) async {
    void checkCancelled() {
      if (isCancelled != null && isCancelled()) {
        throw const BackupCancelledException();
      }
    }

    final encoder = ZipEncoder();
    encoder.startEncode(output);

    onProgress?.call(const BackupProgress(phase: BackupPhase.collectingData));
    checkCancelled();

    final dataByTable = <String, List<Map<String, dynamic>>>{};
    final counts = <String, int>{};
    final referencedRecordingIds = <String>{};

    for (final table in backupEntityTables) {
      final records = <Map<String, dynamic>>[];
      await for (final record in source.readTable(table)) {
        records.add(record.toJson());
        if (table == 'events') {
          referencedRecordingIds.addAll(_recordingIdsIn(record));
        }
      }
      dataByTable[table] = records;
      counts[table] = records.length;
      checkCancelled();
    }

    final deviceRecordingIds = (await source.recordingIdsOnDevice()).toSet();
    final missingAudio = referencedRecordingIds.difference(deviceRecordingIds).toList()
      ..sort();
    final idsToBackUp = deviceRecordingIds.toList()..sort();

    onProgress?.call(BackupProgress(
        phase: BackupPhase.writingRecordings, current: 0, total: idsToBackUp.length));

    final recordingEntries = <BackupRecordingEntry>[];
    for (var i = 0; i < idsToBackUp.length; i++) {
      checkCancelled();
      final id = idsToBackUp[i];
      final bytes = await source.readRecordingBytes(id);
      final sha256Hex = sha256.convert(bytes).toString();

      final archiveFile = ArchiveFile.stream(
        BackupEntryNames.recordingEntry(id),
        InputMemoryStream(bytes),
      )
        ..compression = CompressionType.none
        ..lastModTime = now().millisecondsSinceEpoch ~/ 1000;
      encoder.add(archiveFile, autoClose: true);

      recordingEntries.add(BackupRecordingEntry(
        id: id,
        sizeBytes: bytes.length,
        sha256Hex: sha256Hex,
      ));

      onProgress?.call(BackupProgress(
          phase: BackupPhase.writingRecordings,
          current: i + 1,
          total: idsToBackUp.length));
    }

    checkCancelled();
    onProgress?.call(const BackupProgress(phase: BackupPhase.writingMetadata));

    final manifest = BackupManifest(
      formatVersion: currentBackupFormatVersion,
      createdAt: now(),
      appVersion: await source.appVersion(),
      databaseSchemaVersion: await source.schemaVersion(),
      counts: counts,
      recordings: recordingEntries,
      missingAudio: missingAudio,
    );

    final dataBytes = utf8.encode(jsonEncode(dataByTable));
    encoder.add(
      ArchiveFile.bytes(BackupEntryNames.data, dataBytes)
        ..lastModTime = now().millisecondsSinceEpoch ~/ 1000,
    );

    final manifestBytes = utf8.encode(jsonEncode(manifest.toJson()));
    encoder.add(
      ArchiveFile.bytes(BackupEntryNames.manifest, manifestBytes)
        ..lastModTime = now().millisecondsSinceEpoch ~/ 1000,
    );

    final readmeBytes =
        utf8.encode(buildBackupReadmeText(createdAt: manifest.createdAt));
    encoder.add(
      ArchiveFile.bytes(BackupEntryNames.readme, readmeBytes)
        ..lastModTime = now().millisecondsSinceEpoch ~/ 1000,
    );

    encoder.endEncode();

    return BackupWriteResult(manifest: manifest);
  }

  /// Recording ids referenced by one event's `files` list (JSON, exactly as
  /// stored - see [AttachedFile.toJson]/[AttachedFile.kindRecording]).
  Iterable<String> _recordingIdsIn(BackupEntityRecord eventRecord) sync* {
    final files = eventRecord.data['files'];
    if (files is! List) return;
    for (final f in files) {
      if (f is Map && f['kind'] == AttachedFile.kindRecording && f['id'] is String) {
        yield f['id'] as String;
      }
    }
  }
}
