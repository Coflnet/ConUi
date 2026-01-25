import 'package:uuid/uuid.dart';

enum EventType {
  meeting,
  call,
  message,
  visit,
  trip,
  celebration,
  work,
  social,
  other,
}

class AttachedFile {
  final String id;
  String fileName;
  String filePath;
  String mimeType;
  int size;
  DateTime addedAt;

  AttachedFile({
    String? id,
    required this.fileName,
    required this.filePath,
    required this.mimeType,
    required this.size,
    DateTime? addedAt,
  })  : id = id ?? const Uuid().v4(),
        addedAt = addedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'fileName': fileName,
        'filePath': filePath,
        'mimeType': mimeType,
        'size': size,
        'addedAt': addedAt.toIso8601String(),
      };

  factory AttachedFile.fromJson(Map<String, dynamic> json) => AttachedFile(
        id: json['id'],
        fileName: json['fileName'],
        filePath: json['filePath'],
        mimeType: json['mimeType'],
        size: json['size'],
        addedAt: DateTime.parse(json['addedAt']),
      );

  bool get isImage => mimeType.startsWith('image/');
  bool get isAudio => mimeType.startsWith('audio/');
  bool get isVideo => mimeType.startsWith('video/');
}

class Event {
  final String id;
  String title;
  String? description;
  EventType type;
  DateTime dateTime;
  DateTime? endDateTime;
  String? placeId;
  List<String> participantIds;
  List<AttachedFile> files;
  List<String> objectIds;
  DateTime createdAt;
  DateTime updatedAt;
  bool isDeleted;

  Event({
    String? id,
    required this.title,
    this.description,
    this.type = EventType.other,
    required this.dateTime,
    this.endDateTime,
    this.placeId,
    List<String>? participantIds,
    List<AttachedFile>? files,
    List<String>? objectIds,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.isDeleted = false,
  })  : id = id ?? const Uuid().v4(),
        participantIds = participantIds ?? [],
        files = files ?? [],
        objectIds = objectIds ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  // Get the month key for this event (used for blob organization)
  String get monthKey {
    return '${dateTime.year}-${dateTime.month.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'type': type.name,
        'dateTime': dateTime.toIso8601String(),
        'endDateTime': endDateTime?.toIso8601String(),
        'placeId': placeId,
        'participantIds': participantIds,
        'files': files.map((f) => f.toJson()).toList(),
        'objectIds': objectIds,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'isDeleted': isDeleted,
      };

  factory Event.fromJson(Map<String, dynamic> json) => Event(
        id: json['id'],
        title: json['title'],
        description: json['description'],
        type: EventType.values.firstWhere(
          (e) => e.name == json['type'],
          orElse: () => EventType.other,
        ),
        dateTime: DateTime.parse(json['dateTime']),
        endDateTime: json['endDateTime'] != null
            ? DateTime.parse(json['endDateTime'])
            : null,
        placeId: json['placeId'],
        participantIds: List<String>.from(json['participantIds'] ?? []),
        files: (json['files'] as List<dynamic>?)
                ?.map((f) => AttachedFile.fromJson(f))
                .toList() ??
            [],
        objectIds: List<String>.from(json['objectIds'] ?? []),
        createdAt: DateTime.parse(json['createdAt']),
        updatedAt: DateTime.parse(json['updatedAt']),
        isDeleted: json['isDeleted'] ?? false,
      );

  Event copyWith({
    String? title,
    String? description,
    EventType? type,
    DateTime? dateTime,
    DateTime? endDateTime,
    String? placeId,
    List<String>? participantIds,
    List<AttachedFile>? files,
    List<String>? objectIds,
    bool? isDeleted,
  }) {
    return Event(
      id: id,
      title: title ?? this.title,
      description: description ?? this.description,
      type: type ?? this.type,
      dateTime: dateTime ?? this.dateTime,
      endDateTime: endDateTime ?? this.endDateTime,
      placeId: placeId ?? this.placeId,
      participantIds: participantIds ?? this.participantIds,
      files: files ?? this.files,
      objectIds: objectIds ?? this.objectIds,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      isDeleted: isDeleted ?? this.isDeleted,
    );
  }
}

// Monthly events container for blob storage
class MonthlyEvents {
  final String monthKey;
  List<Event> events;
  DateTime updatedAt;

  MonthlyEvents({
    required this.monthKey,
    List<Event>? events,
    DateTime? updatedAt,
  })  : events = events ?? [],
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'monthKey': monthKey,
        'events': events.map((e) => e.toJson()).toList(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory MonthlyEvents.fromJson(Map<String, dynamic> json) => MonthlyEvents(
        monthKey: json['monthKey'],
        events: (json['events'] as List<dynamic>)
            .map((e) => Event.fromJson(e))
            .toList(),
        updatedAt: DateTime.parse(json['updatedAt']),
      );
}
