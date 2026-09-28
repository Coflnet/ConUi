import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/models/models.dart';

void main() {
  group('Person deathDate JSON compatibility', () {
    test('old JSON (no death fields) parses with defaults', () {
      final oldJson = {
        'id': 'p1',
        'name': 'Ada Lovelace',
        'aliases': <String>[],
        'photoPath': null,
        'birthday': '1815-12-10T00:00:00.000',
        'phoneNumber': null,
        'email': null,
        'address': null,
        'company': null,
        'jobTitle': null,
        'notes': null,
        'customAttributes': <String, String>{},
        'createdAt': '2020-01-01T00:00:00.000',
        'updatedAt': '2020-01-01T00:00:00.000',
        'isDeleted': false,
      };

      final person = Person.fromJson(oldJson);

      expect(person.deathDate, isNull);
      expect(person.birthdayPrecision, DatePrecision.day);
      expect(person.deathDatePrecision, DatePrecision.day);
    });

    test('new JSON with death fields round-trips', () {
      final person = Person(
        name: 'Ada Lovelace',
        birthday: DateTime(1815, 12, 10),
        birthdayPrecision: DatePrecision.day,
        deathDate: DateTime(1852, 11, 27),
        deathDatePrecision: DatePrecision.year,
      );

      final roundTripped = Person.fromJson(person.toJson());

      expect(roundTripped.deathDate, DateTime(1852, 11, 27));
      expect(roundTripped.deathDatePrecision, DatePrecision.year);
      expect(roundTripped.birthdayPrecision, DatePrecision.day);
    });
  });

  group('Person display helpers', () {
    test('displayBirthday/displayDeathDate format by precision', () {
      final person = Person(
        name: 'x',
        birthday: DateTime(1950, 6, 12),
        birthdayPrecision: DatePrecision.year,
        deathDate: DateTime(2020, 3, 1),
        deathDatePrecision: DatePrecision.day,
      );

      expect(person.displayBirthday, '1950');
      expect(person.displayDeathDate, contains('2020'));
    });

    test('lifeDatesLabel combines both dates when both are known', () {
      final person = Person(
        name: 'x',
        birthday: DateTime(1950),
        birthdayPrecision: DatePrecision.year,
        deathDate: DateTime(2020),
        deathDatePrecision: DatePrecision.year,
      );
      expect(person.lifeDatesLabel, '1950 - 2020');
    });

    test('lifeDatesLabel shows "b." with only a birthday', () {
      final person =
          Person(name: 'x', birthday: DateTime(1950), birthdayPrecision: DatePrecision.year);
      expect(person.lifeDatesLabel, 'b. 1950');
    });

    test('lifeDatesLabel shows "d." with only a death date', () {
      final person =
          Person(name: 'x', deathDate: DateTime(2020), deathDatePrecision: DatePrecision.year);
      expect(person.lifeDatesLabel, 'd. 2020');
    });

    test('lifeDatesLabel is null with neither date known', () {
      final person = Person(name: 'x');
      expect(person.lifeDatesLabel, isNull);
    });
  });

  group('Person.copyWith and deathDate', () {
    test('copyWith leaves deathDate unchanged by default', () {
      final person = Person(name: 'x', deathDate: DateTime(2020));
      final unchanged = person.copyWith(name: 'y');
      expect(unchanged.deathDate, DateTime(2020));
    });

    test('copyWith(clearDeathDate: true) clears a previously-set deathDate', () {
      final person = Person(name: 'x', deathDate: DateTime(2020));
      final cleared = person.copyWith(clearDeathDate: true);
      expect(cleared.deathDate, isNull);
    });
  });
}
