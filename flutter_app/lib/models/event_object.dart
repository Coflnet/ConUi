import 'package:uuid/uuid.dart';

class EventObject {
  final String id;
  String name;
  String? description;
  String? category;
  List<String> eventIds; // Events this object was involved in
  DateTime createdAt;
  DateTime updatedAt;
  bool isDeleted;

  EventObject({
    String? id,
    required this.name,
    this.description,
    this.category,
    List<String>? eventIds,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.isDeleted = false,
  })  : id = id ?? const Uuid().v4(),
        eventIds = eventIds ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'category': category,
        'eventIds': eventIds,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'isDeleted': isDeleted,
      };

  factory EventObject.fromJson(Map<String, dynamic> json) => EventObject(
        id: json['id'],
        name: json['name'],
        description: json['description'],
        category: json['category'],
        eventIds: List<String>.from(json['eventIds'] ?? []),
        createdAt: DateTime.parse(json['createdAt']),
        updatedAt: DateTime.parse(json['updatedAt']),
        isDeleted: json['isDeleted'] ?? false,
      );

  EventObject copyWith({
    String? name,
    String? description,
    String? category,
    List<String>? eventIds,
    bool? isDeleted,
  }) {
    return EventObject(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      category: category ?? this.category,
      eventIds: eventIds ?? this.eventIds,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      isDeleted: isDeleted ?? this.isDeleted,
    );
  }
}
