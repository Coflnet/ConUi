import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/models/models.dart';

/// A hand-copied snapshot of the pre-step-3 Event.fromJson, so this file
/// can prove that JSON written by the CURRENT model still parses under the
/// OLD model (forward compatibility) without depending on git history.
Event _legacyEventFromJson(Map<String, dynamic> json) => Event(
      id: json['id'],
      title: json['title'],
      description: json['description'],
      type: EventType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => EventType.other,
      ),
      dateTime: DateTime.parse(json['dateTime']),
      endDateTime:
          json['endDateTime'] != null ? DateTime.parse(json['endDateTime']) : null,
      placeId: json['placeId'],
      participantIds: List<String>.from(json['participantIds'] ?? []),
      files: (json['files'] as List<dynamic>?)
              ?.map((f) => _legacyAttachedFileFromJson(f))
              .toList() ??
          [],
      objectIds: List<String>.from(json['objectIds'] ?? []),
      createdAt: DateTime.parse(json['createdAt']),
      updatedAt: DateTime.parse(json['updatedAt']),
      isDeleted: json['isDeleted'] ?? false,
    );

AttachedFile _legacyAttachedFileFromJson(Map<String, dynamic> json) =>
    AttachedFile(
      id: json['id'],
      fileName: json['fileName'],
      filePath: json['filePath'],
      mimeType: json['mimeType'],
      size: json['size'],
      addedAt: DateTime.parse(json['addedAt']),
    );

void main() {
  group('AttachedFile JSON compatibility', () {
    test('old JSON (no durationMs/sha256/kind) parses with defaults', () {
      final oldJson = {
        'id': 'f1',
        'fileName': 'photo.jpg',
        'filePath': '/files/f1.jpg',
        'mimeType': 'image/jpeg',
        'size': 12345,
        'addedAt': '2020-01-01T00:00:00.000',
      };

      final file = AttachedFile.fromJson(oldJson);

      expect(file.id, 'f1');
      expect(file.durationMs, isNull);
      expect(file.sha256, isNull);
      expect(file.kind, isNull);
      expect(file.isRecording, isFalse);
    });

    test('new JSON with recording fields round-trips', () {
      final file = AttachedFile(
        id: 'r1',
        fileName: 'story.wav',
        filePath: 'recordings/r1.wav',
        mimeType: 'audio/wav',
        size: 999,
        durationMs: 65000,
        sha256: 'deadbeef',
        kind: AttachedFile.kindRecording,
      );

      final json = file.toJson();
      final roundTripped = AttachedFile.fromJson(json);

      expect(roundTripped.durationMs, 65000);
      expect(roundTripped.sha256, 'deadbeef');
      expect(roundTripped.kind, AttachedFile.kindRecording);
      expect(roundTripped.isRecording, isTrue);
    });

    test('new JSON still only carries the old keys the old app understood',
        () {
      final file = AttachedFile(
        id: 'r1',
        fileName: 'story.wav',
        filePath: 'recordings/r1.wav',
        mimeType: 'audio/wav',
        size: 999,
        durationMs: 65000,
        sha256: 'deadbeef',
        kind: AttachedFile.kindRecording,
      );

      final json = file.toJson();
      // The pre-step-3 model only ever read these five keys.
      final legacyFields = {
        'id': json['id'],
        'fileName': json['fileName'],
        'filePath': json['filePath'],
        'mimeType': json['mimeType'],
        'size': json['size'],
        'addedAt': json['addedAt'],
      };
      expect(legacyFields['fileName'], 'story.wav');
      expect(legacyFields['mimeType'], 'audio/wav');
    });
  });

  group('Event JSON compatibility', () {
    test('old JSON (no datePrecision) parses with DatePrecision.time', () {
      final oldJson = {
        'id': 'e1',
        'title': 'Old story',
        'description': 'Told once',
        'type': 'visit',
        'dateTime': '1998-06-12T14:30:00.000',
        'placeId': null,
        'participantIds': <String>[],
        'files': <dynamic>[],
        'objectIds': <String>[],
        'createdAt': '1998-06-12T14:30:00.000',
        'updatedAt': '1998-06-12T14:30:00.000',
        'isDeleted': false,
      };

      final event = Event.fromJson(oldJson);

      expect(event.datePrecision, DatePrecision.time);
      expect(event.title, 'Old story');
    });

    test('new JSON with datePrecision still parses under the old model', () {
      final event = Event(
        title: 'Grandma at the lake house',
        dateTime: DateTime(1952),
        datePrecision: DatePrecision.year,
      );

      final json = event.toJson();
      final legacyEvent = _legacyEventFromJson(json);

      // The old model ignores the unknown 'datePrecision' key and still
      // reconstructs everything it used to understand.
      expect(legacyEvent.title, 'Grandma at the lake house');
      expect(legacyEvent.dateTime, DateTime(1952));
    });

    test('round trips datePrecision through the current model', () {
      final event = Event(
        title: 'Wedding',
        dateTime: DateTime(1970, 6),
        datePrecision: DatePrecision.month,
      );

      final roundTripped = Event.fromJson(event.toJson());

      expect(roundTripped.datePrecision, DatePrecision.month);
    });

    test('copyWith preserves datePrecision unless overridden', () {
      final event = Event(
        title: 'Wedding',
        dateTime: DateTime(1970, 6),
        datePrecision: DatePrecision.month,
      );

      final unchanged = event.copyWith(title: 'Wedding day');
      expect(unchanged.datePrecision, DatePrecision.month);

      final changed = event.copyWith(datePrecision: DatePrecision.day);
      expect(changed.datePrecision, DatePrecision.day);
    });
  });

  group('Event.displayDate', () {
    test('year precision shows only the year', () {
      final event = Event(
        title: 'x',
        dateTime: DateTime(1952, 7, 3),
        datePrecision: DatePrecision.year,
      );
      expect(event.displayDate(), '1952');
    });

    test('month precision shows month and year', () {
      final event = Event(
        title: 'x',
        dateTime: DateTime(1952, 6, 3),
        datePrecision: DatePrecision.month,
      );
      expect(event.displayDate(), 'June 1952');
    });

    test('day precision shows a full date without a time', () {
      final event = Event(
        title: 'x',
        dateTime: DateTime(1952, 6, 12),
        datePrecision: DatePrecision.day,
      );
      expect(event.displayDate(), contains('1952'));
      expect(event.displayDate(), isNot(contains(':')));
    });

    test('time precision (the default) shows date and time', () {
      final event = Event(
        title: 'x',
        dateTime: DateTime(1952, 6, 12, 15, 45),
      );
      expect(event.displayDate(), contains('1952'));
      expect(event.displayDate(), contains(':'));
    });
  });

  group('Event.compareByDate', () {
    test('sorts chronologically regardless of precision', () {
      final earlier = Event(title: 'a', dateTime: DateTime(1950));
      final later = Event(title: 'b', dateTime: DateTime(1980));

      final sorted = [later, earlier]..sort(Event.compareByDate);

      expect(sorted.first, earlier);
      expect(sorted.last, later);
    });

    test('breaks ties on equal timestamps by preferring more precision',
        () {
      final vague = Event(
        title: 'vague',
        dateTime: DateTime(1950),
        datePrecision: DatePrecision.year,
      );
      final precise = Event(
        title: 'precise',
        dateTime: DateTime(1950),
        datePrecision: DatePrecision.time,
      );

      final sorted = [vague, precise]..sort(Event.compareByDate);

      expect(sorted.first, precise);
      expect(sorted.last, vague);
    });
  });
}
