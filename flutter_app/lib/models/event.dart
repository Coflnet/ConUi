import 'package:intl/intl.dart';
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

/// How precisely [Event.dateTime] is actually known. Many family stories
/// only carry a year ("that was around 1952") or a month; forcing a full
/// timestamp on those would fabricate precision that was never told to us.
enum DatePrecision { year, month, day, time }

DatePrecision _datePrecisionFromName(String? name) => DatePrecision.values
    .firstWhere((p) => p.name == name, orElse: () => DatePrecision.time);

/// Formats [date] to match how precisely it's actually known: "1952",
/// "June 1952", "Jun 12, 1952" or, with full time precision, "Jun 12, 1952
/// 3:45 PM" - in [locale] (e.g. from `Localizations.localeOf(context)`), or
/// intl's own default locale if omitted (used by callers with no
/// BuildContext, e.g. plain model unit tests). Shared by [Event.displayDate]
/// and [Person]'s birthday/death date display, which use the same
/// [DatePrecision] vocabulary.
String formatDateWithPrecision(DateTime date, DatePrecision precision, [String? locale]) {
  switch (precision) {
    case DatePrecision.year:
      return DateFormat.y(locale).format(date);
    case DatePrecision.month:
      return DateFormat.yMMMM(locale).format(date);
    case DatePrecision.day:
      return DateFormat.yMMMd(locale).format(date);
    case DatePrecision.time:
      return DateFormat.yMMMd(locale).add_jm().format(date);
  }
}

class AttachedFile {
  /// Marks an [AttachedFile] as an audio recording captured inside this
  /// app (as opposed to e.g. an imported photo or document). See
  /// [AttachedFile.kind].
  static const String kindRecording = 'recording';

  final String id;
  String fileName;
  String filePath;
  String mimeType;
  int size;
  DateTime addedAt;

  /// Playback length in milliseconds. Only meaningful for audio/video
  /// files; null for anything else or when unknown. Optional and additive
  /// so JSON written by older app versions (without this field) still
  /// parses.
  int? durationMs;

  /// SHA-256 of the file's bytes, hex-encoded, computed once the file is
  /// final (see RecordingFileStore). Used to detect corruption and to
  /// avoid re-uploading identical bytes. Optional and additive, like
  /// [durationMs].
  String? sha256;

  /// What kind of attachment this is. Currently only [kindRecording] is a
  /// meaningful value (an audio recording captured in-app via
  /// RecorderController); everything else (imported photos, documents,
  /// audio picked from the file system, ...) leaves this null. Optional
  /// and additive, like [durationMs].
  String? kind;

  AttachedFile({
    String? id,
    required this.fileName,
    required this.filePath,
    required this.mimeType,
    required this.size,
    DateTime? addedAt,
    this.durationMs,
    this.sha256,
    this.kind,
  })  : id = id ?? const Uuid().v4(),
        addedAt = addedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'fileName': fileName,
        'filePath': filePath,
        'mimeType': mimeType,
        'size': size,
        'addedAt': addedAt.toIso8601String(),
        if (durationMs != null) 'durationMs': durationMs,
        if (sha256 != null) 'sha256': sha256,
        if (kind != null) 'kind': kind,
      };

  factory AttachedFile.fromJson(Map<String, dynamic> json) => AttachedFile(
        id: json['id'],
        fileName: json['fileName'],
        filePath: json['filePath'],
        mimeType: json['mimeType'],
        size: json['size'],
        addedAt: DateTime.parse(json['addedAt']),
        durationMs: json['durationMs'] as int?,
        sha256: json['sha256'] as String?,
        kind: json['kind'] as String?,
      );

  bool get isImage => mimeType.startsWith('image/');
  bool get isAudio => mimeType.startsWith('audio/');
  bool get isVideo => mimeType.startsWith('video/');
  bool get isRecording => kind == kindRecording;
}

class Event {
  final String id;
  String title;

  /// Free-text notes about the story. When this event has a recording
  /// ([files] contains an [AttachedFile] with `kind == AttachedFile.
  /// kindRecording`), this field also holds that recording's transcript -
  /// live-transcribed or produced by "transcribe later" - which the user
  /// can freely correct here. There is intentionally no separate
  /// transcript field: the description IS the (editable) transcript once a
  /// recording exists, and plain notes otherwise.
  String? description;
  EventType type;
  DateTime dateTime;

  /// How precisely [dateTime] is known; see [DatePrecision]. Defaults to
  /// [DatePrecision.time] so existing data (which always had a full
  /// timestamp) keeps behaving exactly as before.
  DatePrecision datePrecision;
  DateTime? endDateTime;
  String? placeId;
  List<String> participantIds;

  /// Attachments for this event. A recording (kind ==
  /// AttachedFile.kindRecording) belongs to exactly one event - this one -
  /// for its whole life; recordings are not shared between events.
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
    this.datePrecision = DatePrecision.time,
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

  /// Human-readable date, formatted to match how precisely the date is
  /// actually known: "1952", "June 1952", "Jun 12, 1952" or, with full
  /// time precision, "Jun 12, 1952 3:45 PM" - in [locale] if given (see
  /// [formatDateWithPrecision]).
  String displayDate([String? locale]) =>
      formatDateWithPrecision(dateTime, datePrecision, locale);

  /// Sorts events by date, most imprecise-safe: compares [dateTime]
  /// first (so chronological order is always respected regardless of
  /// precision), then falls back to more-precise-first when the
  /// timestamps are exactly equal (e.g. two "year only" stories both
  /// normalized to Jan 1st).
  static int compareByDate(Event a, Event b) {
    final byDate = a.dateTime.compareTo(b.dateTime);
    if (byDate != 0) return byDate;
    return b.datePrecision.index.compareTo(a.datePrecision.index);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'type': type.name,
        'dateTime': dateTime.toIso8601String(),
        'datePrecision': datePrecision.name,
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
        datePrecision: _datePrecisionFromName(json['datePrecision'] as String?),
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
    DatePrecision? datePrecision,
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
      datePrecision: datePrecision ?? this.datePrecision,
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
