import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/models/person.dart';
import 'package:relationship_manager/services/contact_import_service.dart';

void main() {
  test(
      'vCard imports folded and escaped Unicode fields without native contact access',
      () {
    final people = ContactImportService.parseVCard(
        'BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Zoë Müller\r\nN:Müller;Zoë;;;\r\nEMAIL:zoe@example.test\r\nTEL:+49 123 456\r\nORG:Family\r\nTITLE:Engineer\r\nBDAY:19800403\r\nNOTE:First line\\nSecond\r\n  line\r\nEND:VCARD\r\n');
    final person = people.single;
    expect(person.name, 'Zoë Müller');
    expect(person.email, 'zoe@example.test');
    expect(person.phoneNumber, '+49 123 456');
    expect(person.company, 'Family');
    expect(person.jobTitle, 'Engineer');
    expect(person.birthday, DateTime(1980, 4, 3));
    expect(person.notes, contains('First line\nSecond line'));
  });

  test(
      'normalizes phone/email duplicates but preserves distinct people with the same name',
      () {
    final existing = Person(
        name: 'Alex', email: 'alex@example.test', phoneNumber: '+49 1234');
    expect(
        ContactImportService.isDuplicate(
            Person(name: 'A', email: ' ALEX@example.test '), [existing]),
        isTrue);
    expect(
        ContactImportService.isDuplicate(
            Person(name: 'A', phoneNumber: '0049-1234'), [existing]),
        isTrue);
    expect(ContactImportService.isDuplicate(Person(name: 'Alex'), [existing]),
        isTrue);
    expect(
        ContactImportService.isDuplicate(
            Person(name: 'Alex', email: 'other@example.test'), [existing]),
        isFalse);
  });

  test(
      'malformed non-vCard files fail instead of reporting an empty successful import',
      () {
    expect(() => ContactImportService.parseVCard('not a contact file'),
        throwsFormatException);
  });
}
