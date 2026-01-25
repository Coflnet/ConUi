import 'package:uuid/uuid.dart';

class Person {
  final String id;
  String name;
  List<String> aliases;
  String? photoPath;
  DateTime? birthday;
  String? phoneNumber;
  String? email;
  String? address;
  String? company;
  String? jobTitle;
  String? notes;
  Map<String, String> customAttributes;
  DateTime createdAt;
  DateTime updatedAt;
  bool isDeleted;

  Person({
    String? id,
    required this.name,
    List<String>? aliases,
    this.photoPath,
    this.birthday,
    this.phoneNumber,
    this.email,
    this.address,
    this.company,
    this.jobTitle,
    this.notes,
    Map<String, String>? customAttributes,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.isDeleted = false,
  })  : id = id ?? const Uuid().v4(),
        aliases = aliases ?? [],
        customAttributes = customAttributes ?? {},
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'aliases': aliases,
        'photoPath': photoPath,
        'birthday': birthday?.toIso8601String(),
        'phoneNumber': phoneNumber,
        'email': email,
        'address': address,
        'company': company,
        'jobTitle': jobTitle,
        'notes': notes,
        'customAttributes': customAttributes,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'isDeleted': isDeleted,
      };

  factory Person.fromJson(Map<String, dynamic> json) => Person(
        id: json['id'],
        name: json['name'],
        aliases: List<String>.from(json['aliases'] ?? []),
        photoPath: json['photoPath'],
        birthday:
            json['birthday'] != null ? DateTime.parse(json['birthday']) : null,
        phoneNumber: json['phoneNumber'],
        email: json['email'],
        address: json['address'],
        company: json['company'],
        jobTitle: json['jobTitle'],
        notes: json['notes'],
        customAttributes:
            Map<String, String>.from(json['customAttributes'] ?? {}),
        createdAt: DateTime.parse(json['createdAt']),
        updatedAt: DateTime.parse(json['updatedAt']),
        isDeleted: json['isDeleted'] ?? false,
      );

  Person copyWith({
    String? name,
    List<String>? aliases,
    String? photoPath,
    DateTime? birthday,
    String? phoneNumber,
    String? email,
    String? address,
    String? company,
    String? jobTitle,
    String? notes,
    Map<String, String>? customAttributes,
    bool? isDeleted,
  }) {
    return Person(
      id: id,
      name: name ?? this.name,
      aliases: aliases ?? this.aliases,
      photoPath: photoPath ?? this.photoPath,
      birthday: birthday ?? this.birthday,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      email: email ?? this.email,
      address: address ?? this.address,
      company: company ?? this.company,
      jobTitle: jobTitle ?? this.jobTitle,
      notes: notes ?? this.notes,
      customAttributes: customAttributes ?? this.customAttributes,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      isDeleted: isDeleted ?? this.isDeleted,
    );
  }
}

class Connection {
  final String id;
  String person1Id;
  String person2Id;
  String
      relationshipType; // e.g., "friend", "colleague", "family", "partner", "child", "parent"
  String?
      originEventId; // The event that started this connection (e.g., meeting, wedding, birth)
  String? description;
  DateTime startDate; // When the connection started
  DateTime? endDate; // If the connection ended
  DateTime createdAt;
  DateTime updatedAt;

  Connection({
    String? id,
    required this.person1Id,
    required this.person2Id,
    required this.relationshipType,
    this.originEventId,
    this.description,
    DateTime? startDate,
    this.endDate,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : id = id ?? const Uuid().v4(),
        startDate = startDate ?? DateTime.now(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'person1Id': person1Id,
        'person2Id': person2Id,
        'relationshipType': relationshipType,
        'originEventId': originEventId,
        'description': description,
        'startDate': startDate.toIso8601String(),
        'endDate': endDate?.toIso8601String(),
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory Connection.fromJson(Map<String, dynamic> json) => Connection(
        id: json['id'],
        person1Id: json['person1Id'],
        person2Id: json['person2Id'],
        relationshipType: json['relationshipType'],
        originEventId: json['originEventId'],
        description: json['description'],
        startDate: json['startDate'] != null
            ? DateTime.parse(json['startDate'])
            : null,
        endDate:
            json['endDate'] != null ? DateTime.parse(json['endDate']) : null,
        createdAt: DateTime.parse(json['createdAt']),
        updatedAt: DateTime.parse(json['updatedAt']),
      );

  Connection copyWith({
    String? relationshipType,
    String? originEventId,
    String? description,
    DateTime? startDate,
    DateTime? endDate,
  }) {
    return Connection(
      id: id,
      person1Id: person1Id,
      person2Id: person2Id,
      relationshipType: relationshipType ?? this.relationshipType,
      originEventId: originEventId ?? this.originEventId,
      description: description ?? this.description,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }
}
