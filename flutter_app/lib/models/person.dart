import 'package:uuid/uuid.dart';

import 'event.dart' show DatePrecision, formatDateWithPrecision;

DatePrecision _datePrecisionOrDay(String? name) => DatePrecision.values
    .firstWhere((p) => p.name == name, orElse: () => DatePrecision.day);

class Person {
  final String id;
  String name;
  List<String> aliases;
  String? photoPath;
  DateTime? birthday;

  /// How precisely [birthday] is known; see [DatePrecision]. Defaults to
  /// [DatePrecision.day] - unlike an event, a birthday is never recorded
  /// with a time of day, and most family stories at least know the day.
  /// Optional and additive, like [deathDate], so JSON written before this
  /// field existed (which always meant "day precision") still parses the
  /// same way.
  DatePrecision birthdayPrecision;

  /// When this person died, if known. Optional and additive so JSON
  /// written by older app versions (without this field) still parses.
  DateTime? deathDate;

  /// How precisely [deathDate] is known; see [DatePrecision]. Defaults to
  /// [DatePrecision.day], same reasoning as [birthdayPrecision].
  DatePrecision deathDatePrecision;

  String? phoneNumber;
  String? email;
  String? address;
  String? company;
  String? jobTitle;
  String? notes;
  Map<String, String> customAttributes;
  Map<String, String> storyFacts;
  DateTime createdAt;
  DateTime updatedAt;
  bool isDeleted;

  Person({
    String? id,
    required this.name,
    List<String>? aliases,
    this.photoPath,
    this.birthday,
    this.birthdayPrecision = DatePrecision.day,
    this.deathDate,
    this.deathDatePrecision = DatePrecision.day,
    this.phoneNumber,
    this.email,
    this.address,
    this.company,
    this.jobTitle,
    this.notes,
    Map<String, String>? customAttributes,
    Map<String, String>? storyFacts,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.isDeleted = false,
  })  : id = id ?? const Uuid().v4(),
        aliases = aliases ?? [],
        customAttributes = customAttributes ?? {},
        storyFacts = storyFacts ?? {},
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// [birthday] formatted to match [birthdayPrecision] (in [locale] if
  /// given - see [formatDateWithPrecision]), or null if unknown.
  String? displayBirthday([String? locale]) =>
      birthday == null ? null : formatDateWithPrecision(birthday!, birthdayPrecision, locale);

  /// [deathDate] formatted to match [deathDatePrecision] (in [locale] if
  /// given), or null if unknown (or the person is presumed alive).
  String? displayDeathDate([String? locale]) =>
      deathDate == null ? null : formatDateWithPrecision(deathDate!, deathDatePrecision, locale);

  /// A compact life-dates label for tight spaces (e.g. graph nodes):
  /// "1950 - 2020" with both dates known, "$bornPrefix 1950" or "$diedPrefix
  /// 2020" with only one, or null with neither. [bornPrefix]/[diedPrefix]
  /// default to the English "b."/"d." abbreviations; a caller with an
  /// [AppLocalizations] (this model stays Flutter-free, see
  /// `relationship_text.dart`'s doc comment for why) should pass its own
  /// localized ones instead.
  String? lifeDatesLabel({String? locale, String bornPrefix = 'b.', String diedPrefix = 'd.'}) {
    final b = displayBirthday(locale);
    final d = displayDeathDate(locale);
    if (b != null && d != null) return '$b - $d';
    if (b != null) return '$bornPrefix $b';
    if (d != null) return '$diedPrefix $d';
    return null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'aliases': aliases,
        'photoPath': photoPath,
        'birthday': birthday?.toIso8601String(),
        'birthdayPrecision': birthdayPrecision.name,
        'deathDate': deathDate?.toIso8601String(),
        'deathDatePrecision': deathDatePrecision.name,
        'phoneNumber': phoneNumber,
        'email': email,
        'address': address,
        'company': company,
        'jobTitle': jobTitle,
        'notes': notes,
        'customAttributes': customAttributes,
        'storyFacts': storyFacts,
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
        birthdayPrecision: _datePrecisionOrDay(json['birthdayPrecision'] as String?),
        deathDate:
            json['deathDate'] != null ? DateTime.parse(json['deathDate']) : null,
        deathDatePrecision: _datePrecisionOrDay(json['deathDatePrecision'] as String?),
        phoneNumber: json['phoneNumber'],
        email: json['email'],
        address: json['address'],
        company: json['company'],
        jobTitle: json['jobTitle'],
        notes: json['notes'],
        customAttributes:
            Map<String, String>.from(json['customAttributes'] ?? {}),
        storyFacts: Map<String, String>.from(json['storyFacts'] ?? {}),
        createdAt: DateTime.parse(json['createdAt']),
        updatedAt: DateTime.parse(json['updatedAt']),
        isDeleted: json['isDeleted'] ?? false,
      );

  Person copyWith({
    String? name,
    List<String>? aliases,
    String? photoPath,
    DateTime? birthday,
    DatePrecision? birthdayPrecision,
    DateTime? deathDate,
    bool clearDeathDate = false,
    DatePrecision? deathDatePrecision,
    String? phoneNumber,
    String? email,
    String? address,
    String? company,
    String? jobTitle,
    String? notes,
    Map<String, String>? customAttributes,
    Map<String, String>? storyFacts,
    bool? isDeleted,
  }) {
    return Person(
      id: id,
      name: name ?? this.name,
      aliases: aliases ?? this.aliases,
      photoPath: photoPath ?? this.photoPath,
      birthday: birthday ?? this.birthday,
      birthdayPrecision: birthdayPrecision ?? this.birthdayPrecision,
      deathDate: clearDeathDate ? null : (deathDate ?? this.deathDate),
      deathDatePrecision: deathDatePrecision ?? this.deathDatePrecision,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      email: email ?? this.email,
      address: address ?? this.address,
      company: company ?? this.company,
      jobTitle: jobTitle ?? this.jobTitle,
      notes: notes ?? this.notes,
      customAttributes: customAttributes ?? this.customAttributes,
      storyFacts: storyFacts ?? this.storyFacts,
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

  /// Soft-delete flag, same convention as [Person.isDeleted]/[Place.isDeleted]
  /// etc. Optional and additive so JSON written before this field existed -
  /// which was always a non-deleted connection - still parses as `false`.
  bool isDeleted;
  bool isInferred;
  List<String> sourceEventIds;

  Connection({
    String? id,
    required this.person1Id,
    required this.person2Id,
    required this.relationshipType,
    this.isInferred = false,
    List<String>? sourceEventIds,
    this.originEventId,
    this.description,
    DateTime? startDate,
    this.endDate,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.isDeleted = false,
  })  : id = id ?? const Uuid().v4(),
        sourceEventIds = sourceEventIds ?? [],
        startDate = startDate ?? DateTime.now(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'person1Id': person1Id,
        'person2Id': person2Id,
        'relationshipType': relationshipType,
        'isInferred': isInferred,
        'sourceEventIds': sourceEventIds,
        'originEventId': originEventId,
        'description': description,
        'startDate': startDate.toIso8601String(),
        'endDate': endDate?.toIso8601String(),
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'isDeleted': isDeleted,
      };

  factory Connection.fromJson(Map<String, dynamic> json) => Connection(
        id: json['id'],
        person1Id: json['person1Id'],
        person2Id: json['person2Id'],
        relationshipType: json['relationshipType'],
        isInferred: json['isInferred'] ?? false,
        sourceEventIds: List<String>.from(json['sourceEventIds'] ?? []),
        originEventId: json['originEventId'],
        description: json['description'],
        startDate: json['startDate'] != null
            ? DateTime.parse(json['startDate'])
            : null,
        endDate:
            json['endDate'] != null ? DateTime.parse(json['endDate']) : null,
        createdAt: DateTime.parse(json['createdAt']),
        updatedAt: DateTime.parse(json['updatedAt']),
        isDeleted: json['isDeleted'] ?? false,
      );

  Connection copyWith({
    String? relationshipType,
    bool? isInferred,
    List<String>? sourceEventIds,
    String? originEventId,
    String? description,
    DateTime? startDate,
    DateTime? endDate,
    bool? isDeleted,
  }) {
    return Connection(
      id: id,
      person1Id: person1Id,
      person2Id: person2Id,
      relationshipType: relationshipType ?? this.relationshipType,
      isInferred: isInferred ?? this.isInferred,
      sourceEventIds: sourceEventIds ?? this.sourceEventIds,
      originEventId: originEventId ?? this.originEventId,
      description: description ?? this.description,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      isDeleted: isDeleted ?? this.isDeleted,
    );
  }
}
