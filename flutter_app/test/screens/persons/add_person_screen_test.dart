import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/models/person.dart';
import 'package:relationship_manager/screens/persons/add_person_screen.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/local_draft_store.dart';
import '../support/fake_database_service.dart';

class _DelayedPreferences extends InMemorySharedPreferencesStore {
  final Completer<void> ready;
  _DelayedPreferences(this.ready, Map<String, Object> data)
      : super.withData(data);
  @override
  Future<Map<String, Object>> getAll() async {
    await ready.future;
    return super.getAll();
  }
}

class _FailAfterWriteDatabase extends FakeDatabaseService {
  bool fail = true;
  @override
  Future<void> savePerson(Person person,
      {bool recordPendingChange = true}) async {
    await super.savePerson(person);
    if (fail) {
      fail = false;
      throw StateError('disk unavailable');
    }
  }
}

Future<void> _open(WidgetTester tester, FakeDatabaseService db,
    {Person? person}) async {
  await tester.pumpWidget(ChangeNotifierProvider<DatabaseService>.value(
      value: db,
      child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) =>
                                  AddPersonScreen(existingPerson: person))),
                      child: const Text('open')))))));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
      'clearing optional profile fields and birthday persists while source facts remain',
      (tester) async {
    final person = Person(
        name: 'Ada',
        email: 'old@example.test',
        phoneNumber: '123',
        birthday: DateTime(1980),
        storyFacts: {'s': 'A fact'});
    final db = FakeDatabaseService()..persons[person.id] = person;
    await _open(tester, db, person: person);
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), '');
    await tester.enterText(find.widgetWithText(TextFormField, 'Phone'), '');
    await tester.tap(find.byIcon(Icons.clear).first);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final saved = db.persons[person.id]!;
    expect(saved.email, isNull);
    expect(saved.phoneNumber, isNull);
    expect(saved.birthday, isNull);
    expect(saved.storyFacts, person.storyFacts);
  });

  testWidgets(
      'failed save releases spinner and retry reuses the person identity',
      (tester) async {
    final db = _FailAfterWriteDatabase();
    await _open(tester, db);
    await tester.enterText(find.widgetWithText(TextFormField, 'Name *'), 'Ada');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'Could not save your changes. They are still here. Try again.'),
        findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(db.persons, hasLength(1));
  });

  testWidgets(
      'Back keeps editing or saves a persistent draft that restores on reopening',
      (tester) async {
    final db = FakeDatabaseService();
    await _open(tester, db);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Name *'), 'Draft Ada');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, 'Draft Ada'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save draft'));
    await tester.pumpAndSettle();
    expect(db.persons, isEmpty);
    expect(await LocalDraftStore.read('person.new'), isNotNull);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, 'Draft Ada'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(await LocalDraftStore.read('person.new'), isNull);
  });
  testWidgets('late draft loading never overwrites text already entered',
      (tester) async {
    final ready = Completer<void>();
    SharedPreferencesStorePlatform.instance = _DelayedPreferences(ready, {
      'flutter.form_draft.v1.person.new': jsonEncode({
        'id': 'old-draft',
        'fields': ['Older draft', '', '', '', '', '', '', ''],
        'birthday': null,
        'deathDate': null,
      }),
    });
    await _open(tester, FakeDatabaseService());
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Name *'), 'New typing');
    ready.complete();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, 'New typing'), findsOneWidget);
    expect(find.text('Older draft'), findsNothing);
  });
}
