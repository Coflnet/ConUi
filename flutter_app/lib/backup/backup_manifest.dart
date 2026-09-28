import 'backup_format.dart';

/// One recording included in a backup: enough to find it in the archive
/// (by [id], see [BackupEntryNames.recordingEntry]) and to verify it
/// ([sizeBytes]/[sha256Hex]) before trusting its bytes.
class BackupRecordingEntry {
  final String id;
  final int sizeBytes;
  final String sha256Hex;

  const BackupRecordingEntry({
    required this.id,
    required this.sizeBytes,
    required this.sha256Hex,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'size': sizeBytes,
        'sha256': sha256Hex,
      };

  factory BackupRecordingEntry.fromJson(Map<String, dynamic> json) =>
      BackupRecordingEntry(
        id: json['id'] as String,
        sizeBytes: json['size'] as int,
        sha256Hex: json['sha256'] as String,
      );
}

/// manifest.json: everything needed to show the user what a backup
/// contains, and to verify it, without reading the whole archive.
class BackupManifest {
  final int formatVersion;
  final DateTime createdAt;
  final String appVersion;
  final int databaseSchemaVersion;

  /// Number of entities of each table (see [backupEntityTables]) written to
  /// data.json, INCLUDING soft-deleted ones.
  final Map<String, int> counts;

  final List<BackupRecordingEntry> recordings;

  /// Ids of recordings that a story (event) refers to but whose bytes were
  /// not on this device when the backup was made.
  final List<String> missingAudio;

  const BackupManifest({
    required this.formatVersion,
    required this.createdAt,
    required this.appVersion,
    required this.databaseSchemaVersion,
    required this.counts,
    required this.recordings,
    required this.missingAudio,
  });

  int get totalRecordingBytes =>
      recordings.fold(0, (sum, r) => sum + r.sizeBytes);

  Map<String, dynamic> toJson() => {
        'formatVersion': formatVersion,
        'createdAt': createdAt.toIso8601String(),
        'appVersion': appVersion,
        'databaseSchemaVersion': databaseSchemaVersion,
        'counts': counts,
        'recordings': recordings.map((r) => r.toJson()).toList(),
        'missingAudio': missingAudio,
      };

  factory BackupManifest.fromJson(Map<String, dynamic> json) => BackupManifest(
        formatVersion: json['formatVersion'] as int,
        createdAt: DateTime.parse(json['createdAt'] as String),
        appVersion: json['appVersion'] as String? ?? 'unknown',
        databaseSchemaVersion: json['databaseSchemaVersion'] as int? ?? 0,
        counts: Map<String, int>.from(json['counts'] as Map? ?? {}),
        recordings: (json['recordings'] as List? ?? [])
            .map((e) => BackupRecordingEntry.fromJson(
                Map<String, dynamic>.from(e as Map)))
            .toList(),
        missingAudio:
            List<String>.from(json['missingAudio'] as List? ?? const []),
      );
}
