// Sync index stored locally and synced as blob
class SyncIndex {
  Map<String, int> personVersions; // personId -> version
  Map<String, int> placeVersions;
  Map<String, int> objectVersions;
  Map<String, int> eventMonthVersions; // monthKey -> version
  Map<String, int> fileVersions; // fileId -> version
  int lastSyncTimestamp;
  DateTime updatedAt;

  SyncIndex({
    Map<String, int>? personVersions,
    Map<String, int>? placeVersions,
    Map<String, int>? objectVersions,
    Map<String, int>? eventMonthVersions,
    Map<String, int>? fileVersions,
    this.lastSyncTimestamp = 0,
    DateTime? updatedAt,
  })  : personVersions = personVersions ?? {},
        placeVersions = placeVersions ?? {},
        objectVersions = objectVersions ?? {},
        eventMonthVersions = eventMonthVersions ?? {},
        fileVersions = fileVersions ?? {},
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'personVersions': personVersions,
        'placeVersions': placeVersions,
        'objectVersions': objectVersions,
        'eventMonthVersions': eventMonthVersions,
        'fileVersions': fileVersions,
        'lastSyncTimestamp': lastSyncTimestamp,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory SyncIndex.fromJson(Map<String, dynamic> json) => SyncIndex(
        personVersions: Map<String, int>.from(json['personVersions'] ?? {}),
        placeVersions: Map<String, int>.from(json['placeVersions'] ?? {}),
        objectVersions: Map<String, int>.from(json['objectVersions'] ?? {}),
        eventMonthVersions:
            Map<String, int>.from(json['eventMonthVersions'] ?? {}),
        fileVersions: Map<String, int>.from(json['fileVersions'] ?? {}),
        lastSyncTimestamp: json['lastSyncTimestamp'] ?? 0,
        updatedAt: json['updatedAt'] != null
            ? DateTime.parse(json['updatedAt'])
            : DateTime.now(),
      );
}

// Pending change for offline-first sync
class PendingChange {
  final String id;
  final String entityType; // person, place, object, event, file
  final String entityId;
  final String operation; // create, update, delete
  final Map<String, dynamic> data;
  final DateTime createdAt;
  bool synced;

  PendingChange({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.data,
    DateTime? createdAt,
    this.synced = false,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'entityType': entityType,
        'entityId': entityId,
        'operation': operation,
        'data': data,
        'createdAt': createdAt.toIso8601String(),
        'synced': synced,
      };

  factory PendingChange.fromJson(Map<String, dynamic> json) => PendingChange(
        id: json['id'],
        entityType: json['entityType'],
        entityId: json['entityId'],
        operation: json['operation'],
        data: Map<String, dynamic>.from(json['data']),
        createdAt: DateTime.parse(json['createdAt']),
        synced: json['synced'] ?? false,
      );
}
