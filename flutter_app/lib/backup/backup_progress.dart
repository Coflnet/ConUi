/// Coarse phase a backup/restore run is currently in, for progress UI.
enum BackupPhase {
  collectingData,
  writingRecordings,
  writingMetadata,
  verifying,
  restoringRecordings,
  restoringData,
}

/// A progress update for a long-running backup or restore. [current]/[total]
/// are phase-local (e.g. "recording 3 of 12"); [total] of 0 means "unknown
/// yet".
class BackupProgress {
  final BackupPhase phase;
  final int current;
  final int total;

  const BackupProgress({required this.phase, this.current = 0, this.total = 0});
}

typedef BackupProgressCallback = void Function(BackupProgress progress);

/// Polled at safe checkpoints by [BackupWriter]/[BackupRestorer]; returning
/// true aborts the run with a [BackupCancelledException].
typedef BackupCancelCheck = bool Function();
