import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/models/person.dart';
import 'package:relationship_manager/screens/contacts/contacts_import_screen.dart';
import 'package:relationship_manager/services/contact_import_service.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'support/fake_database_service.dart';

class _Contacts extends ContactImportService {
  final List<Person> people;
  bool denied = false;
  _Contacts(this.people);
  @override
  bool get supportsDeviceContacts => true;
  @override
  Future<List<Person>> readDevice() async {
    if (denied) throw ContactPermissionDenied();
    return people;
  }

  @override
  Future<List<Person>?> readFile() async => people;
}

class _FailSecond extends FakeDatabaseService {
  int writes = 0;
  @override
  Future<void> savePerson(Person person,
      {bool recordPendingChange = true}) async {
    if (++writes == 2) throw StateError('disk unavailable');
    await super.savePerson(person);
  }
}

Future<void> _open(WidgetTester tester, FakeDatabaseService db,
        ContactImportService service) =>
    tester.pumpWidget(ChangeNotifierProvider<DatabaseService>.value(
        value: db,
        child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ContactsImportScreen(service: service))));

void main() {
  testWidgets(
      'preselects only novel contacts, skips repeated source contacts and honors deselection',
      (tester) async {
    final db = FakeDatabaseService();
    final old = Person(name: 'Old', email: 'old@example.test');
    db.persons[old.id] = old;
    await _open(
        tester,
        db,
        _Contacts([
          Person(name: 'Existing', email: 'OLD@example.test'),
          Person(name: 'Ada', email: 'ada@example.test'),
          Person(name: 'Again Ada', email: 'ada@example.test'),
          Person(name: 'Ben')
        ]));
    await tester.tap(find.text('Choose vCard file (.vcf)'));
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile), findsNWidgets(3));
    expect(find.text('Import selected (2)'), findsOneWidget);
    await tester.tap(find.text('Ben'));
    await tester.pump();
    await tester.tap(find.text('Import selected (1)'));
    await tester.pumpAndSettle();
    expect(
        db.persons.values.map((p) => p.name), unorderedEquals(['Old', 'Ada']));
  });

  testWidgets(
      'permission denial offers file fallback without erasing the current selection',
      (tester) async {
    final source = _Contacts([Person(name: 'Ada')]);
    await _open(tester, FakeDatabaseService(), source);
    await tester.tap(find.text('Choose vCard file (.vcf)'));
    await tester.pumpAndSettle();
    source.denied = true;
    await tester.tap(find.text('Choose from address book'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('Contact access was not allowed'), findsOneWidget);
    expect(find.text('Import selected (1)'), findsOneWidget);
    expect(find.text('Choose vCard file (.vcf)'), findsOneWidget);
  });

  testWidgets(
      'partial import failure retains remaining selection and retry never duplicates success',
      (tester) async {
    final db = _FailSecond();
    await _open(
        tester, db, _Contacts([Person(name: 'Ada'), Person(name: 'Ben')]));
    await tester.tap(find.text('Choose vCard file (.vcf)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import selected (2)'));
    await tester.pumpAndSettle();
    expect(db.persons, hasLength(1));
    expect(find.text('Import selected (1)'), findsOneWidget);
    expect(find.textContaining('Some contacts could not be added'),
        findsOneWidget);
    await tester.tap(find.text('Import selected (1)'));
    await tester.pumpAndSettle();
    expect(
        db.persons.values.map((p) => p.name), unorderedEquals(['Ada', 'Ben']));
    expect(find.text('Import selected (0)'), findsOneWidget);
  });
}
