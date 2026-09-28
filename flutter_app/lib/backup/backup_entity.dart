/// One row of one entity table (persons/connections/places/events/objects),
/// as backed up and restored.
///
/// [data] is exactly the decoded JSON document the database stores in that
/// table's `data` column - not re-derived from a model's toJson(), so a
/// field this code doesn't know about (an older or newer schema's extra
/// key) survives a backup/restore round trip untouched. [isDeleted] is
/// carried separately because it lives in the row's own `is_deleted`
/// column, not inside every model's JSON (Connection, notably, doesn't
/// serialize it - see the final report for why this representation was
/// chosen over going through the model classes).
class BackupEntityRecord {
  final String table;
  final String id;
  final Map<String, dynamic> data;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isDeleted;

  const BackupEntityRecord({
    required this.table,
    required this.id,
    required this.data,
    required this.createdAt,
    required this.updatedAt,
    required this.isDeleted,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'data': data,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'isDeleted': isDeleted,
      };

  factory BackupEntityRecord.fromJson(String table, Map<String, dynamic> json) {
    return BackupEntityRecord(
      table: table,
      id: json['id'] as String,
      data: Map<String, dynamic>.from(json['data'] as Map),
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      isDeleted: json['isDeleted'] as bool? ?? false,
    );
  }
}
