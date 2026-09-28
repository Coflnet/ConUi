import 'dart:convert';
import 'dart:typed_data';

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
import 'backup_stream_hash.dart';

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
/// avoid that).
///
/// Each recording is read straight off disk in chunks when
/// [BackupDataSource.recordingFilePath] gives one (native/desktop - see
/// [_writeRecordingFromFile]): [write] never holds more than one chunk of
/// it in memory at a time, regardless of the recording's total size, and
/// never accumulates previously-written recordings - see the peak-memory
/// regression tests in test/backup/large_recording_test.dart. On platforms
/// with no such file (web), the recording has to be assembled in memory
/// first - see [_writeRecordingFromStream] - which matches this app's
/// existing web limitations elsewhere (see backup_service.dart).
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
      final modTime = now().millisecondsSinceEpoch ~/ 1000;
      final filePath = await source.recordingFilePath(id);

      final _RecordingWriteInfo info;
      if (filePath != null) {
        info = _writeRecordingFromFile(id, filePath, modTime);
      } else {
        info = await _writeRecordingFromStream(id, source.openRecordingStream(id), modTime);
      }

      encoder.add(info.archiveFile, autoClose: true);
      recordingEntries.add(BackupRecordingEntry(
        id: id,
        sizeBytes: info.sizeBytes,
        sha256Hex: info.sha256Hex,
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

/// What one recording contributed to the zip, needed for its
/// [BackupRecordingEntry] once [BackupWriter.write] has added it.
class _RecordingWriteInfo {
  final ArchiveFile archiveFile;
  final int sizeBytes;
  final String sha256Hex;
  const _RecordingWriteInfo(
      {required this.archiveFile, required this.sizeBytes, required this.sha256Hex});
}

/// Reads and hashes recording [id] straight off the file at [filePath] -
/// this is the fast path used whenever [BackupDataSource.recordingFilePath]
/// gives one (native/desktop): the recording is read through exactly
/// twice, each time in [backupStreamChunkBytes]-sized chunks straight from
/// disk (via package:archive's InputFileStream, which never materializes
/// more than one chunk at a time), never fully resident in memory either
/// time however large it is:
///  1. [hashInputStreamForZipEntry] computes both the CRC-32 the zip local
///     header needs before any data is written, and the SHA-256 this app's
///     manifest records - in one pass, so the second (write) pass doesn't
///     have to redo either.
///  2. The zip encoder itself streams the actual bytes into the archive
///     when [ZipEncoder.add] is called on the returned [ArchiveFile] - see
///     [_PrecomputedCrcFileContent]'s doc comment for how the precomputed
///     CRC-32 gets the encoder to skip re-deriving it (which would
///     otherwise mean a third full read).
_RecordingWriteInfo _writeRecordingFromFile(String id, String filePath, int modTime) {
  final fileStream = InputFileStream(filePath);
  final sizeBytes = fileStream.length;
  final hashed = hashInputStreamForZipEntry(fileStream);
  final archiveFile = ArchiveFile.file(
    BackupEntryNames.recordingEntry(id),
    sizeBytes,
    _PrecomputedCrcFileContent(fileStream),
  )
    ..compression = CompressionType.none
    ..crc32 = hashed.crc32
    ..lastModTime = modTime;
  return _RecordingWriteInfo(
      archiveFile: archiveFile, sizeBytes: sizeBytes, sha256Hex: hashed.sha256Hex);
}

/// Reads recording [id] from [stream] - the fallback used when
/// [BackupDataSource.recordingFilePath] returned null (web, which has no
/// real file to stream from a second time - see its doc comment). The
/// whole recording ends up resident in memory here regardless of how it's
/// assembled, so this just does so directly rather than pretending
/// otherwise.
Future<_RecordingWriteInfo> _writeRecordingFromStream(
    String id, Stream<List<int>> stream, int modTime) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    builder.add(chunk);
  }
  final bytes = builder.takeBytes();
  final sha256Hex = sha256.convert(bytes).toString();
  final archiveFile = ArchiveFile.stream(
    BackupEntryNames.recordingEntry(id),
    InputMemoryStream(bytes),
  )
    ..compression = CompressionType.none
    ..lastModTime = modTime;
  return _RecordingWriteInfo(
      archiveFile: archiveFile, sizeBytes: bytes.length, sha256Hex: sha256Hex);
}

/// A [FileContent] wrapping an already-hashed [stream] (see
/// [_writeRecordingFromFile]), so [ZipEncoder.add] takes its
/// "already-compressed" fast path instead of re-reading [stream] just to
/// (re-)compute a CRC-32 that's already known - the encoder only takes that
/// fast path when [FileContent.isCompressed] is true, which the default
/// [FileContent]/plain stream-backed content never reports, so this
/// override is what actually saves the extra read. [stream] must already
/// be rewound to position 0 (see [hashInputStreamForZipEntry]) and is read
/// through exactly once more, in [ZipEncoder]'s own chunked
/// [OutputStream.writeStream].
class _PrecomputedCrcFileContent extends FileContent {
  final InputStream stream;
  _PrecomputedCrcFileContent(this.stream);

  @override
  int get length => stream.length;

  @override
  InputStream getStream({bool decompress = true}) => stream;

  @override
  void write(OutputStream output) => output.writeStream(stream);

  @override
  Future<void> close() => stream.close();

  @override
  void closeSync() => stream.closeSync();

  @override
  bool get isCompressed => true;
}
