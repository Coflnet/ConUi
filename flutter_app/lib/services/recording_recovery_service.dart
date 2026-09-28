import '../models/models.dart';
import 'database_service.dart';
import 'recording_file_store.dart';

/// Runs at start-up to find recordings that never got a chance to finish -
/// the app crashed, or a browser tab was closed, mid-recording - and
/// repairs them so the audio captured so far isn't lost.
///
/// A recording stuck in [RecordingLifecycleState.recording] has valid PCM
/// bytes but a WAV header that (on native) still says zero length, or (on
/// web) was never written at all. [recoverIncompleteRecordings] rewrites
/// that header from the bytes actually present - exactly what
/// [RecordingFileStore.finalizeRecording] does at a normal stop - and marks
/// the row [RecordingLifecycleState.recovered] so the UI can offer to
/// attach it to a story or discard it.
class RecordingRecoveryService {
  final RecordingFileStore store;
  final DatabaseService db;

  RecordingRecoveryService(this.store, this.db);

  Future<List<LocalRecordingState>> recoverIncompleteRecordings() async {
    final incomplete = await db
        .getLocalRecordingsByState(RecordingLifecycleState.recording);
    final recovered = <LocalRecordingState>[];

    for (final recording in incomplete) {
      if (!await store.exists(recording.id)) {
        // Nothing was ever actually written; drop the orphaned row.
        await db.deleteLocalRecordingRow(recording.id);
        continue;
      }

      final result = await store.finalizeRecording(recording.id);
      final updated = recording.copyWith(
        state: RecordingLifecycleState.recovered,
        sizeBytes: result.sizeBytes,
        sha256: result.sha256Hex,
        durationMs: result.durationMs,
      );
      await db.saveLocalRecording(updated);
      recovered.add(updated);
    }

    return recovered;
  }
}
