/// Lifecycle of a recording's bytes on THIS device, tracked in the
/// `local_recordings` table (see db_migrations.dart, migration 2).
///
/// - [recording]: still being captured (or the app crashed/closed while it
///   was - indistinguishable until start-up recovery runs).
/// - [complete]: normally finished via RecorderController.stop().
/// - [recovered]: found in the [recording] state at start-up, repaired
///   (WAV header rewritten to match the bytes actually captured) and
///   surfaced to the user to attach to a story or discard.
enum RecordingLifecycleState { recording, complete, recovered }

RecordingLifecycleState _lifecycleStateFromName(String? name) =>
    RecordingLifecycleState.values.firstWhere(
      (s) => s.name == name,
      orElse: () => RecordingLifecycleState.recording,
    );

/// One row of local (never synced) bookkeeping about a recording's bytes in
/// a RecordingFileStore: which event it belongs to (if any yet) and its
/// [RecordingLifecycleState].
///
/// See RecordingFileStore's doc comment for the full recording-deletion
/// rule; in short, a row here (and the bytes it describes) is only removed
/// after explicit user confirmation, never merely because its event was
/// soft-deleted.
class LocalRecordingState {
  final String id;
  String? eventId;
  RecordingLifecycleState state;
  int? sizeBytes;
  String? sha256;
  int? durationMs;
  DateTime createdAt;
  DateTime updatedAt;

  LocalRecordingState({
    required this.id,
    this.eventId,
    this.state = RecordingLifecycleState.recording,
    this.sizeBytes,
    this.sha256,
    this.durationMs,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  LocalRecordingState copyWith({
    String? eventId,
    RecordingLifecycleState? state,
    int? sizeBytes,
    String? sha256,
    int? durationMs,
  }) {
    return LocalRecordingState(
      id: id,
      eventId: eventId ?? this.eventId,
      state: state ?? this.state,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      sha256: sha256 ?? this.sha256,
      durationMs: durationMs ?? this.durationMs,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }

  Map<String, dynamic> toRow() => {
        'id': id,
        'event_id': eventId,
        'state': state.name,
        'size': sizeBytes,
        'sha256': sha256,
        'duration_ms': durationMs,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory LocalRecordingState.fromRow(Map<String, dynamic> row) =>
      LocalRecordingState(
        id: row['id'] as String,
        eventId: row['event_id'] as String?,
        state: _lifecycleStateFromName(row['state'] as String?),
        sizeBytes: row['size'] as int?,
        sha256: row['sha256'] as String?,
        durationMs: row['duration_ms'] as int?,
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
      );
}
