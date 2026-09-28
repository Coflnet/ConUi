import 'backup_manifest.dart';
import 'backup_source.dart';

/// What a restore actually did, in plain structured data - the settings
/// screen turns this into the "what was added, updated, skipped... and
/// every warning" result screen text (see backup_strings.dart).
class RestoreResult {
  final BackupManifest manifest;
  final List<EntityMergeResult> entities;
  final List<RecordingRestoreResult> recordings;

  const RestoreResult({
    required this.manifest,
    required this.entities,
    required this.recordings,
  });

  int _entityCount(MergeOutcome outcome) =>
      entities.where((e) => e.outcome == outcome).length;

  int get addedCount => _entityCount(MergeOutcome.added);
  int get updatedCount => _entityCount(MergeOutcome.updated);
  int get skippedCount => _entityCount(MergeOutcome.skipped);

  int _recordingCount(RecordingOutcome outcome) =>
      recordings.where((r) => r.outcome == outcome).length;

  int get recordingsRestoredCount =>
      _recordingCount(RecordingOutcome.restored);
  int get recordingsAlreadyPresentCount =>
      _recordingCount(RecordingOutcome.alreadyPresent);
  int get recordingsConflictCount =>
      _recordingCount(RecordingOutcome.conflictKept);
  int get recordingsChecksumMismatchCount =>
      _recordingCount(RecordingOutcome.checksumMismatch);
  int get recordingsInvalidIdCount =>
      _recordingCount(RecordingOutcome.invalidId);

  bool get hasWarnings =>
      recordingsConflictCount > 0 ||
      recordingsChecksumMismatchCount > 0 ||
      recordingsInvalidIdCount > 0;
}
