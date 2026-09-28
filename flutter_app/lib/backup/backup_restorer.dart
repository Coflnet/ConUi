import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'backup_entity.dart';
import 'backup_exceptions.dart';
import 'backup_format.dart';
import 'backup_manifest.dart';
import 'backup_progress.dart';
import 'backup_restore_result.dart';
import 'backup_source.dart';
import 'backup_stream_hash.dart';

/// Read-only parse of an archive: enough to show the user what's inside
/// before they confirm a restore (date, counts, recordings, missing
/// audio), without writing anything anywhere.
class BackupPreview {
  final BackupManifest manifest;
  const BackupPreview({required this.manifest});
}

/// Parses, validates and applies a Relationship Manager backup archive.
///
/// Pure Dart: no Flutter or dart:io imports, so it's exercised directly by
/// fast unit tests against an in-memory [BackupDataSink] fake. The concrete
/// [InputStream] is chosen by the caller (an `InputFileStream` for a real
/// file on native, an `InputMemoryStream` for bytes picked on web).
///
/// Safety rules (see the class-level hardening notes in backup_source.dart
/// and the final report for why): entries are only ever looked up by the
/// exact names this format defines (manifest.json, data.json,
/// recordings/<id>.wav for an <id> taken from the manifest and validated
/// with [isSafeRecordingId]) - never by iterating or trusting whatever
/// entry names happen to be present in the archive. A declared
/// [BackupManifest.formatVersion] this code doesn't know is refused before
/// anything else is read. Every size/count is checked against
/// [BackupSafetyLimits] before the corresponding bytes are decompressed.
class BackupRestorer {
  /// Overridable for tests, which would otherwise need to build
  /// impractically large archives to exercise these refusals - production
  /// code never passes this and gets [BackupSafetyLimits] as-is.
  final int maxEntryCount;
  final int maxManifestBytes;
  final int maxDataJsonBytes;
  final int maxRecordingBytes;
  final int maxTotalRecordingBytes;

  BackupRestorer({
    this.maxEntryCount = BackupSafetyLimits.maxEntryCount,
    this.maxManifestBytes = BackupSafetyLimits.maxManifestBytes,
    this.maxDataJsonBytes = BackupSafetyLimits.maxDataJsonBytes,
    this.maxRecordingBytes = BackupSafetyLimits.maxRecordingBytes,
    this.maxTotalRecordingBytes = BackupSafetyLimits.maxTotalRecordingBytes,
  });

  /// Parses and validates the archive far enough to show the user a
  /// preview, without writing anything. Throws a [BackupRestoreException]
  /// subtype for anything wrong with the archive itself.
  BackupPreview preview(InputStream input) {
    final opened = _open(input);
    return BackupPreview(manifest: opened.manifest);
  }

  /// Full structural + checksum verification: every recording's bytes are
  /// read back and checked against the manifest, and data.json is checked
  /// to parse with the counts the manifest claims. Returns a description of
  /// each problem found (empty = archive is intact). Used right after
  /// writing a backup, before telling the user it succeeded, and can also
  /// be used standalone. Never touches any [BackupDataSink].
  List<String> verify(InputStream input) {
    final opened = _open(input);
    final problems = <String>[];

    for (final entry in opened.manifest.recordings) {
      final file = opened.archive.findFile(BackupEntryNames.recordingEntry(entry.id));
      if (file == null) {
        problems.add('Recording ${entry.id} is listed in the manifest but '
            'missing from the archive.');
        continue;
      }
      if (file.size != entry.sizeBytes) {
        problems.add('Recording ${entry.id} has size ${file.size}, '
            'expected ${entry.sizeBytes}.');
        continue;
      }
      final actualSha256 = _hashRecordingEntry(file).sha256Hex;
      if (actualSha256 != entry.sha256Hex) {
        problems.add('Recording ${entry.id} failed its checksum check.');
      }
    }

    final dataJson = _readDataJson(opened.archive);
    for (final table in backupEntityTables) {
      final actual = (dataJson[table] as List?)?.length ?? 0;
      final expected = opened.manifest.counts[table] ?? 0;
      if (actual != expected) {
        problems.add('$table: manifest says $expected, data.json has $actual.');
      }
    }

    return problems;
  }

  /// Applies the archive's contents to [sink]: recordings first (verified
  /// against the manifest checksum, one at a time), then every entity
  /// write as a single atomic transaction - see the ordering rationale on
  /// [BackupDataSink.applyEntityRestore].
  Future<RestoreResult> apply(
    InputStream input,
    BackupDataSink sink, {
    DateTime Function() now = DateTime.now,
    BackupCancelCheck? isCancelled,
    BackupProgressCallback? onProgress,
  }) async {
    void checkCancelled() {
      if (isCancelled != null && isCancelled()) {
        throw const BackupCancelledException();
      }
    }

    final opened = _open(input);
    final manifest = opened.manifest;

    onProgress?.call(BackupProgress(
        phase: BackupPhase.restoringRecordings,
        current: 0,
        total: manifest.recordings.length));

    final recordingResults = <RecordingRestoreResult>[];
    for (var i = 0; i < manifest.recordings.length; i++) {
      checkCancelled();
      final entry = manifest.recordings[i];
      recordingResults.add(await _restoreOneRecording(entry, opened.archive, sink));
      onProgress?.call(BackupProgress(
          phase: BackupPhase.restoringRecordings,
          current: i + 1,
          total: manifest.recordings.length));
    }

    checkCancelled();
    onProgress?.call(const BackupProgress(phase: BackupPhase.restoringData));

    final dataJson = _readDataJson(opened.archive);
    final entityResults = <EntityMergeResult>[];
    final toApply = <BackupEntityRecord>[];

    for (final table in backupEntityTables) {
      final rawList = (dataJson[table] as List?) ?? const [];
      for (final raw in rawList) {
        final record =
            BackupEntityRecord.fromJson(table, Map<String, dynamic>.from(raw as Map));
        final existing = await sink.existingUpdatedAt(table, record.id);
        final MergeOutcome outcome;
        if (existing == null) {
          outcome = MergeOutcome.added;
        } else if (record.updatedAt.isAfter(existing)) {
          outcome = MergeOutcome.updated;
        } else {
          outcome = MergeOutcome.skipped;
        }
        entityResults
            .add(EntityMergeResult(table: table, id: record.id, outcome: outcome));
        if (outcome != MergeOutcome.skipped) {
          toApply.add(record);
        }
      }
    }

    checkCancelled();
    await sink.applyEntityRestore(toApply);

    return RestoreResult(
      manifest: manifest,
      entities: entityResults,
      recordings: recordingResults,
    );
  }

  Future<RecordingRestoreResult> _restoreOneRecording(
    BackupRecordingEntry entry,
    Archive archive,
    BackupDataSink sink,
  ) async {
    if (!isSafeRecordingId(entry.id)) {
      return RecordingRestoreResult(id: entry.id, outcome: RecordingOutcome.invalidId);
    }
    if (entry.sizeBytes > maxRecordingBytes) {
      return RecordingRestoreResult(
          id: entry.id, outcome: RecordingOutcome.checksumMismatch);
    }

    final file = archive.findFile(BackupEntryNames.recordingEntry(entry.id));
    if (file == null) {
      // Declared in the manifest but absent from the archive: treat the
      // same as a failed checksum - either way, these bytes cannot be
      // trusted or stored.
      return RecordingRestoreResult(
          id: entry.id, outcome: RecordingOutcome.checksumMismatch);
    }

    // Hashes (and, on success, re-reads) this entry a chunk at a time
    // rather than materializing it whole - see _hashRecordingEntry's doc
    // comment - so restoring a multi-hundred-MB recording never holds more
    // than one chunk of it in memory, matching BackupWriter's own
    // guarantee on the way in (see the peak-memory regression tests in
    // test/backup/large_recording_test.dart).
    final hashed = _hashRecordingEntry(file);
    if (hashed.sha256Hex != entry.sha256Hex) {
      return RecordingRestoreResult(
          id: entry.id, outcome: RecordingOutcome.checksumMismatch);
    }

    final existingChecksum = await sink.existingRecordingChecksum(entry.id);
    if (existingChecksum == hashed.sha256Hex) {
      return RecordingRestoreResult(
          id: entry.id, outcome: RecordingOutcome.alreadyPresent);
    }
    if (existingChecksum != null) {
      return RecordingRestoreResult(
          id: entry.id, outcome: RecordingOutcome.conflictKept);
    }

    await sink.storeVerifiedRecordingStream(
      entry.id,
      chunksOfInputStream(hashed.stream),
      sha256Hex: hashed.sha256Hex,
    );
    return RecordingRestoreResult(id: entry.id, outcome: RecordingOutcome.restored);
  }

  /// The SHA-256 of one recording entry's bytes, computed a chunk at a time
  /// wherever possible instead of fully decompressing/materializing the
  /// entry first (see [ArchiveFile.readBytes]): recordings are always
  /// written in "store" (uncompressed) mode by BackupWriter, so for an
  /// honest archive the entry's raw content IS its final bytes, and reading
  /// it via `getStream(decompress: false)` streams straight from the
  /// picked backup file's own InputStream rather than buffering. Also
  /// returns that same [InputStream], rewound to the start, so a caller
  /// that goes on to restore this recording (see [_restoreOneRecording])
  /// doesn't need a second full read to get the bytes back.
  ///
  /// Falls back to the old (fully-buffering) path for anything that isn't
  /// plain "store" mode - which nothing this app's own BackupWriter ever
  /// produces, but a foreign or corrupted archive might claim; the
  /// fallback is safe either way, since bytes that don't actually match
  /// [BackupRecordingEntry.sha256Hex] are rejected regardless of how they
  /// were read.
  _HashedRecordingEntry _hashRecordingEntry(ArchiveFile file) {
    final rawContent = file.rawContent;
    if (file.compression == CompressionType.none && rawContent != null) {
      final stream = rawContent.getStream(decompress: false);
      return _HashedRecordingEntry(
          sha256Hex: sha256OfInputStream(stream), stream: stream);
    }
    final bytes = file.readBytes() ?? Uint8List(0);
    return _HashedRecordingEntry(
        sha256Hex: sha256.convert(bytes).toString(), stream: InputMemoryStream(bytes));
  }

  Map<String, dynamic> _readDataJson(Archive archive) {
    final file =
        _requireEntry(archive, BackupEntryNames.data, maxDataJsonBytes, 'data.json');
    final bytes = file.readBytes();
    if (bytes == null) {
      throw BackupFormatException('data.json could not be read.');
    }
    try {
      return Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
    } on FormatException catch (e) {
      throw BackupFormatException('data.json is not valid JSON: $e');
    }
  }

  _OpenedArchive _open(InputStream input) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeStream(input);
    } on BackupRestoreException {
      rethrow;
    } catch (e) {
      throw BackupArchiveCorruptException(e);
    }

    // A garbled or truncated file that still happens not to throw while
    // being parsed (the zip decoder is lenient: no central directory found
    // just means no entries, rather than an exception) decodes to an empty
    // archive. Treat that as corrupt too, rather than reporting the more
    // confusing "missing manifest.json".
    if (archive.isEmpty) {
      throw BackupArchiveCorruptException(
          'no entries could be read from this file - it is likely truncated '
          'or not a zip file at all');
    }

    if (archive.length > maxEntryCount) {
      throw BackupTooLargeException(
          'This archive has ${archive.length} entries, more than this app '
          'will ever produce or accept ($maxEntryCount).');
    }

    final manifestFile =
        _requireEntry(archive, BackupEntryNames.manifest, maxManifestBytes, 'manifest.json');
    final manifestBytes = manifestFile.readBytes();
    if (manifestBytes == null) {
      throw BackupFormatException('manifest.json could not be read.');
    }
    final BackupManifest manifest;
    try {
      manifest = BackupManifest.fromJson(
          Map<String, dynamic>.from(jsonDecode(utf8.decode(manifestBytes)) as Map));
    } on FormatException catch (e) {
      throw BackupFormatException('manifest.json is not valid JSON: $e');
    }

    if (manifest.formatVersion != currentBackupFormatVersion) {
      throw UnsupportedBackupVersionException(manifest.formatVersion);
    }

    // data.json must exist too (checked eagerly so a broken archive is
    // reported up front rather than partway through applying it), but its
    // bytes aren't read until they're actually needed.
    _requireEntry(archive, BackupEntryNames.data, maxDataJsonBytes, 'data.json');

    final totalRecordingBytes =
        manifest.recordings.fold<int>(0, (sum, r) => sum + r.sizeBytes);
    if (totalRecordingBytes > maxTotalRecordingBytes) {
      throw BackupTooLargeException(
          'This archive declares $totalRecordingBytes bytes of recordings, '
          'more than this app will accept in one restore.');
    }

    return _OpenedArchive(archive: archive, manifest: manifest);
  }

  ArchiveFile _requireEntry(Archive archive, String name, int maxBytes, String label) {
    final file = archive.findFile(name);
    if (file == null) {
      throw BackupFormatException('This archive is missing $label.');
    }
    if (file.size > maxBytes) {
      throw BackupTooLargeException('$label is ${file.size} bytes, larger than '
          'this app will accept ($maxBytes).');
    }
    return file;
  }
}

class _OpenedArchive {
  final Archive archive;
  final BackupManifest manifest;
  const _OpenedArchive({required this.archive, required this.manifest});
}

/// Result of [BackupRestorer._hashRecordingEntry]: the recording's actual
/// SHA-256, plus an [InputStream] rewound to the start ready to be read
/// again for the bytes themselves.
class _HashedRecordingEntry {
  final String sha256Hex;
  final InputStream stream;
  const _HashedRecordingEntry({required this.sha256Hex, required this.stream});
}
