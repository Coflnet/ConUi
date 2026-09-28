import 'backup_entity.dart';

/// Everything [BackupWriter] needs to read from local storage. Implemented
/// against the real database/recording store by DatabaseBackupAdapter (see
/// database_backup_adapter.dart); tests implement it directly against
/// in-memory fakes, which is what keeps the writer itself fast to test.
abstract class BackupDataSource {
  /// The app version to record in the manifest.
  Future<String> appVersion();

  /// The database schema version to record in the manifest (see
  /// db_migrations.dart's `latestDbVersion`).
  Future<int> schemaVersion();

  /// Every row of [table] (one of [backupEntityTables]), including
  /// soft-deleted ones. [table] is always one of the constants in
  /// backup_format.dart.
  Stream<BackupEntityRecord> readTable(String table);

  /// Every recording id whose bytes currently exist on this device,
  /// regardless of whether any story references it yet (an
  /// in-progress/orphaned recording is still backed up - losing it would
  /// contradict the whole point of this feature).
  Future<List<String>> recordingIdsOnDevice();

  /// A filesystem path to recording [id]'s bytes, when the current platform
  /// keeps recordings as real files (native/desktop - see
  /// RecordingFileStore.filePathIfAvailable). When this returns non-null,
  /// BackupWriter reads and hashes the recording directly off disk in
  /// chunks (via package:archive's InputFileStream), never holding more
  /// than one chunk in memory regardless of how large the recording is -
  /// see the peak-memory regression tests in
  /// test/backup/large_recording_test.dart. Returns null on platforms with
  /// no such file (web, where recordings live in IndexedDB) - callers fall
  /// back to [openRecordingStream] there, which for now still has to
  /// assemble the whole recording in memory first (an existing limitation
  /// of the web RecordingFileStore this backup feature doesn't change - see
  /// the final report).
  Future<String?> recordingFilePath(String id);

  /// [id]'s bytes (WAV header included) as a stream, for platforms where
  /// [recordingFilePath] returned null.
  Stream<List<int>> openRecordingStream(String id);
}

/// How one entity record was handled while applying a restore.
enum MergeOutcome { added, updated, skipped }

/// The result of merging one [BackupEntityRecord] into local storage.
class EntityMergeResult {
  final String table;
  final String id;
  final MergeOutcome outcome;

  const EntityMergeResult(
      {required this.table, required this.id, required this.outcome});
}

/// How one recording from the archive was handled while applying a
/// restore.
enum RecordingOutcome {
  /// Bytes verified against the manifest checksum and written; nothing with
  /// this id existed locally yet.
  restored,

  /// Bytes verified, but this id already existed locally with the exact
  /// same checksum - nothing to do.
  alreadyPresent,

  /// This id already existed locally with a DIFFERENT checksum. The
  /// existing recording is kept; the archive's copy is discarded. Reported
  /// to the user as a conflict, never silently resolved.
  conflictKept,

  /// The bytes in the archive don't match the checksum the manifest
  /// declared for this id. Reported as a warning; this recording is not
  /// written.
  checksumMismatch,

  /// The manifest declared an id that isn't safe to use as a recording id
  /// (e.g. a path-traversal-shaped string) - see isSafeRecordingId() in
  /// backup_format.dart. Never looked up in the archive or handed to
  /// storage; reported as a warning.
  invalidId,
}

class RecordingRestoreResult {
  final String id;
  final RecordingOutcome outcome;

  const RecordingRestoreResult({required this.id, required this.outcome});
}

/// Everything [BackupRestorer] needs to write into local storage.
/// Implemented against the real database/recording store by
/// DatabaseBackupAdapter; tests implement it directly against in-memory
/// fakes.
///
/// Recordings and entities are deliberately two separate write paths (see
/// [storeVerifiedRecordingStream] vs [applyEntityRestore]) so the restorer
/// can process one recording's bytes at a time - never holding more than
/// one in memory - while still applying every entity write as a single
/// atomic transaction, and while guaranteeing every recording a restored
/// story refers to is safely on disk before that story's data is
/// committed.
abstract class BackupDataSink {
  /// `updatedAt` of the existing local row for [table]/[id], or null if no
  /// such row exists yet. Used to decide [MergeOutcome].
  Future<DateTime?> existingUpdatedAt(String table, String id);

  /// The SHA-256 (hex) currently on record for recording [id] on this
  /// device, or null if this device doesn't have it.
  Future<String?> existingRecordingChecksum(String id);

  /// Writes one recording's bytes (WAV header included) that the restorer
  /// has ALREADY verified against the manifest checksum and confirmed has
  /// no conflicting local copy - streamed in [wavBytes] chunk by chunk
  /// (never the whole recording resident in memory at once; see
  /// BackupRestorer, which computes the SHA-256 this same way, off the same
  /// archive entry, before deciding whether to call this at all) rather
  /// than as one Uint8List. Must persist the bytes in the
  /// RecordingFileStore and update local bookkeeping. Called once per
  /// restored recording, sequentially, strictly before [applyEntityRestore]
  /// is called for the same restore.
  Future<void> storeVerifiedRecordingStream(String id, Stream<List<int>> wavBytes,
      {required String sha256Hex});

  /// Applies every entity write for one restore (only records this restore
  /// decided to add or update - see [MergeOutcome]; already-current ones
  /// aren't passed here at all, matching "running the same restore twice
  /// changes nothing") as a single atomic transaction: either all of it
  /// lands, or none of it does.
  Future<void> applyEntityRestore(List<BackupEntityRecord> entities);
}
