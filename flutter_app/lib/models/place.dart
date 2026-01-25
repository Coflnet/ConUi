import 'package:uuid/uuid.dart';

class Place {
  final String id;
  String name;
  double latitude;
  double longitude;
  String? description;
  String? address;
  String? category; // e.g., "home", "work", "restaurant", "venue"
  DateTime createdAt;
  DateTime updatedAt;
  bool isDeleted;

  Place({
    String? id,
    required this.name,
    required this.latitude,
    required this.longitude,
    this.description,
    this.address,
    this.category,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.isDeleted = false,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'latitude': latitude,
        'longitude': longitude,
        'description': description,
        'address': address,
        'category': category,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'isDeleted': isDeleted,
      };

  factory Place.fromJson(Map<String, dynamic> json) => Place(
        id: json['id'],
        name: json['name'],
        latitude: json['latitude'] is int
            ? (json['latitude'] as int).toDouble()
            : json['latitude'],
        longitude: json['longitude'] is int
            ? (json['longitude'] as int).toDouble()
            : json['longitude'],
        description: json['description'],
        address: json['address'],
        category: json['category'],
        createdAt: DateTime.parse(json['createdAt']),
        updatedAt: DateTime.parse(json['updatedAt']),
        isDeleted: json['isDeleted'] ?? false,
      );

  Place copyWith({
    String? name,
    double? latitude,
    double? longitude,
    String? description,
    String? address,
    String? category,
    bool? isDeleted,
  }) {
    return Place(
      id: id,
      name: name ?? this.name,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      description: description ?? this.description,
      address: address ?? this.address,
      category: category ?? this.category,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      isDeleted: isDeleted ?? this.isDeleted,
    );
  }
}
