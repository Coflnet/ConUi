import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart' as fp;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/database_service.dart';
import '../services/recording_file_store.dart';
import 'backup_destination.dart';
import 'backup_exceptions.dart';
import 'backup_format.dart';
import 'backup_manifest.dart';
import 'backup_progress.dart';
import 'backup_restore_result.dart';
import 'backup_restorer.dart';
import 'backup_writer.dart';
import 'database_backup_adapter.dart';

/// What one recording's file (WAV in a story's attachments) looks like to
/// the "this backup will include" preview, before anything is written.
class BackupPlan {
  final Map<String, int> counts;
  final int recordingCount;
  final int recordingBytes;
  final int missingAudioCount;

  const BackupPlan({
    required this.counts,
    required this.recordingCount,
    required this.recordingBytes,
    required this.missingAudioCount,
  });
}

sealed class BackupCreateOutcome {
  const BackupCreateOutcome();
}

class BackupCreateSuccess extends BackupCreateOutcome {
  final BackupManifest manifest;
  final BackupSaveLocation location;
  const BackupCreateSuccess({required this.manifest, required this.location});
}

class BackupCreateCancelled extends BackupCreateOutcome {
  const BackupCreateCancelled();
}

class BackupCreateFailed extends BackupCreateOutcome {
  final String message;
  const BackupCreateFailed(this.message);
}

/// A backup file the user picked, kept re-openable via [open] rather than
/// as a single already-opened [InputStream]. [InputStream] is a stateful,
/// position-advancing reader (see InputMemoryStream/InputFileStream in
/// package:archive); a restore always reads the archive twice - once to
/// preview it, once to apply it - and each read must start from the very
/// beginning, which a single shared stream instance can't do once it's
/// partially consumed. [open] is cheap to call more than once: on native
/// it's a fresh file handle at the file's start; on web it's a fresh view
/// over bytes already held in memory.
class PickedBackupFile {
  final InputStream Function() open;
  const PickedBackupFile(this.open);
}

/// Top-level orchestration for the backup/restore feature: wires the pure
/// [BackupWriter]/[BackupRestorer] to the real database and recording
/// store (via [DatabaseBackupAdapter]) and to a platform-appropriate save
/// destination / file picker. This is what the settings screen (and the
/// backup/restore flow widgets under lib/backup/) call - none of them talk
/// to BackupWriter/BackupRestorer/DatabaseBackupAdapter directly.
class BackupService {
  final DatabaseService databaseService;
  final RecordingFileStore recordingStore;

  /// Overridable so tests can supply a destination backed by a temp
  /// directory instead of a real file_picker/path_provider platform
  /// channel - production code never passes this and gets the real
  /// platform-appropriate provider (see backup_destination.dart).
  final BackupDestinationProvider Function() _destinationProviderFactory;

  BackupService({
    required this.databaseService,
    RecordingFileStore? recordingStore,
    BackupDestinationProvider Function()? destinationProviderFactory,
  })  : recordingStore = recordingStore ?? createRecordingFileStore(),
        _destinationProviderFactory =
            destinationProviderFactory ?? createBackupDestinationProvider;

  /// Above this (very roughly estimated) total recording size, creating a
  /// backup on web is worth warning about first - see backup_writer.dart's
  /// doc comment and the final report for why web can't avoid building the
  /// whole archive in memory. Chosen so a typical phone/laptop browser tab
  /// (which can usually hold at least a low number of GB before the tab is
  /// at risk) still has comfortable headroom over the backup's peak memory
  /// (roughly: archive size + one recording's bytes transiently).
  static const int webSizeWarnThresholdBytes = 300 * 1024 * 1024; // 300 MB

  static const String _lastBackupAtPrefKey = 'backup_last_success_at';

  DatabaseBackupAdapter get _adapter =>
      DatabaseBackupAdapter(databaseService: databaseService, recordingStore: recordingStore);

  // ---------------- Create backup ----------------

  /// What a backup would contain right now, without writing anything -
  /// drives the "this backup will include..." confirmation before the user
  /// commits to creating one.
  Future<BackupPlan> planBackup() async {
    final adapter = _adapter;
    final counts = <String, int>{};
    final referencedIds = <String>{};

    for (final table in backupEntityTables) {
      var count = 0;
      await for (final record in adapter.readTable(table)) {
        count++;
        if (table == 'events') {
          final files = record.data['files'];
          if (files is List) {
            for (final f in files) {
              if (f is Map && f['kind'] == 'recording' && f['id'] is String) {
                referencedIds.add(f['id'] as String);
              }
            }
          }
        }
      }
      counts[table] = count;
    }

    final deviceIds = (await recordingStore.listIds()).toSet();
    var recordingBytes = 0;
    for (final id in deviceIds) {
      recordingBytes += await recordingStore.size(id);
    }
    final missingAudioCount = referencedIds.difference(deviceIds).length;

    return BackupPlan(
      counts: counts,
      recordingCount: deviceIds.length,
      recordingBytes: recordingBytes,
      missingAudioCount: missingAudioCount,
    );
  }

  /// Creates a backup end to end: picks/prepares a destination, streams the
  /// archive, verifies it by reading it back, and only then commits it
  /// (renames into place on native, triggers a download on web). Returns
  /// [BackupCreateCancelled] if the user cancelled a desktop save dialog or
  /// [isCancelled] reported a cancellation mid-write - either way, no
  /// partial file is left behind.
  Future<BackupCreateOutcome> createBackup({
    BackupProgressCallback? onProgress,
    BackupCancelCheck? isCancelled,
  }) async {
    final target =
        await _destinationProviderFactory().prepareTarget(_suggestedFileName(DateTime.now()));
    if (target == null) return const BackupCreateCancelled();

    try {
      final result = await BackupWriter().write(
        source: _adapter,
        output: target.output,
        isCancelled: isCancelled,
        onProgress: onProgress,
      );

      await target.finish();
      onProgress?.call(const BackupProgress(phase: BackupPhase.verifying));
      final verifyInput = await target.openForVerification();
      final problems = BackupRestorer().verify(verifyInput);
      if (problems.isNotEmpty) {
        await target.abort();
        return BackupCreateFailed(
            'The backup did not verify correctly and was discarded:\n${problems.join('\n')}');
      }

      final location = await target.commit();
      await _recordLastBackupAt(result.manifest.createdAt);
      return BackupCreateSuccess(manifest: result.manifest, location: location);
    } on BackupCancelledException {
      await target.abort();
      return const BackupCreateCancelled();
    } catch (e) {
      await target.abort();
      return BackupCreateFailed(e.toString());
    }
  }

  String _suggestedFileName(DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    return 'relationship-manager-backup-${now.year}-${two(now.month)}-${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}.zip';
  }

  // ---------------- Restore ----------------

  /// Lets the user pick a backup file. Returns null if they cancelled.
  /// Reads the WHOLE file into memory on web (file_picker's only option
  /// there for local files); streams from disk on native.
  ///
  /// Returns a re-openable [PickedBackupFile] rather than a single
  /// [InputStream]: an [InputStream] is a stateful, position-advancing
  /// reader, and both [previewRestore] and [applyRestore] need to read the
  /// archive from the very start independently (a restore always previews
  /// before applying) - reusing one partially-read stream for the second
  /// read corrupted it (see the final report for how this was caught).
  Future<PickedBackupFile?> pickBackupFile() async {
    final result = await fp.FilePicker.platform.pickFiles(
      type: fp.FileType.custom,
      allowedExtensions: ['zip'],
      withData: kIsWeb,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.single;
    if (kIsWeb) {
      final bytes = file.bytes;
      if (bytes == null) {
        throw StateError('The picked file had no data available.');
      }
      return PickedBackupFile(() => InputMemoryStream(bytes));
    }
    final path = file.path;
    if (path == null) {
      throw StateError('The picked file had no path available.');
    }
    return PickedBackupFile(() => InputFileStream(path));
  }

  /// Parses and validates [picked] far enough to show the user what it
  /// contains, without writing anything. Throws a [BackupRestoreException]
  /// subtype if the archive is unreadable/unsupported/corrupt.
  BackupPreview previewRestore(PickedBackupFile picked) =>
      BackupRestorer().preview(picked.open());

  /// Merges [picked]'s contents into local storage - see
  /// BackupDataSink.applyEntityRestore's doc comment for the atomicity and
  /// ordering guarantees.
  Future<RestoreResult> applyRestore(
    PickedBackupFile picked, {
    BackupProgressCallback? onProgress,
    BackupCancelCheck? isCancelled,
  }) {
    return BackupRestorer()
        .apply(picked.open(), _adapter, onProgress: onProgress, isCancelled: isCancelled);
  }

  // ---------------- Status for the settings screen ----------------

  Future<DateTime?> getLastBackupAt() async {
    final prefs = await SharedPreferences.getInstance();
    final iso = prefs.getString(_lastBackupAtPrefKey);
    return iso == null ? null : DateTime.tryParse(iso);
  }

  Future<void> _recordLastBackupAt(DateTime when) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastBackupAtPrefKey, when.toIso8601String());
  }

  /// Total bytes every recording currently takes up on this device.
  Future<int> recordingsSpaceBytes() async {
    final ids = await recordingStore.listIds();
    var total = 0;
    for (final id in ids) {
      total += await recordingStore.size(id);
    }
    return total;
  }

  /// How many recordings on this device were created after [since] (the
  /// last successful backup, normally) - drives the "N recordings were
  /// made since your last backup" reminder.
  Future<int> recordingsCreatedAfter(DateTime since) async {
    final ids = await recordingStore.listIds();
    var count = 0;
    for (final id in ids) {
      final row = await databaseService.getLocalRecording(id);
      if (row != null && row.createdAt.isAfter(since)) count++;
    }
    return count;
  }
}
