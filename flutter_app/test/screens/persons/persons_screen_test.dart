// Regression test: PersonsScreen used to load its list once in initState
// and never listen to DatabaseService again, so a restore or a sync -
// both of which write persons straight to the database and call
// DatabaseService.notifyListeners()/notifyDataRestored() rather than going
// through this screen - left the list showing stale data until the user
// navigated away and back.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/screens/persons/persons_screen.dart';
import 'package:relationship_manager/services/database_service.dart';

import '../support/fake_database_service.dart';

Future<void> _pumpPersonsScreen(WidgetTester tester, DatabaseService db) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<DatabaseService>.value(
      value: db,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PersonsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'refreshes the list when DatabaseService notifies, without navigating away and back',
      (tester) async {
    final db = FakeDatabaseService();
    final anna = Person(id: 'anna', name: 'Anna');
    db.persons[anna.id] = anna;

    await _pumpPersonsScreen(tester, db);

    expect(find.text('Anna'), findsOneWidget);
    expect(find.text('Bert'), findsNothing);

    // Simulate a restore/sync writing a new person straight to the
    // database, the same way DatabaseBackupAdapter/SyncService do -
    // *not* through this screen's own _addPerson()/_openPersonDetail()
    // reload paths.
    final bert = Person(id: 'bert', name: 'Bert');
    await db.savePerson(bert);
    await tester.pumpAndSettle();

    expect(find.text('Anna'), findsOneWidget);
    expect(find.text('Bert'), findsOneWidget);
  });

  testWidgets(
      'stops listening once disposed (no leaked listener/late setState)',
      (tester) async {
    final db = FakeDatabaseService();
    await _pumpPersonsScreen(tester, db);

    // Navigate away so PersonsScreen is disposed.
    await tester.pumpWidget(
      ChangeNotifierProvider<DatabaseService>.value(
        value: db,
        child: const MaterialApp(home: Scaffold(body: SizedBox())),
      ),
    );
    await tester.pumpAndSettle();

    // Would throw if the disposed screen's _loadPersons were still
    // registered as a listener and called setState() on an unmounted
    // State.
    await db.savePerson(Person(id: 'carla', name: 'Carla'));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'returning from person detail after the list is disposed does not reload it',
      (tester) async {
    final db = FakeDatabaseService();
    db.persons['anna'] = Person(id: 'anna', name: 'Anna');
    final showPersons = ValueNotifier(true);
    addTearDown(showPersons.dispose);
    await tester.pumpWidget(ChangeNotifierProvider<DatabaseService>.value(
      value: db,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ValueListenableBuilder<bool>(
          valueListenable: showPersons,
          builder: (_, visible, __) => visible
              ? const PersonsScreen()
              : const Scaffold(body: Text('Replacement list')),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anna'));
    await tester.pumpAndSettle();

    // Changing Home's responsive layout recreates its PersonsScreen subtree
    // while the detail route stays open. Dispose only that underlying list.
    showPersons.value = false;
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('Replacement list'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
