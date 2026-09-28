import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/relationships/relationship_type.dart';
import 'package:relationship_manager/screens/persons/add_connection_dialog.dart';
import 'package:relationship_manager/services/database_service.dart';

import '../support/fake_database_service.dart';

Future<void> _pumpDialogHost(
  WidgetTester tester,
  DatabaseService db,
  Person viewedPerson,
  List<Person> allPersons, {
  List<Connection> allConnections = const [],
}) async {
  await tester.pumpWidget(
    // The Provider must sit *above* MaterialApp's own Navigator: showDialog() pushes
    // the dialog as a sibling route on that Navigator, not as a descendant of whatever
    // built the button, so a Provider scoped only under `home:` would not be visible
    // from inside the dialog (matches how main.dart wraps the whole app, not just one
    // screen).
    ChangeNotifierProvider<DatabaseService>.value(
      value: db,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showAddConnectionDialog(
                  context,
                  viewedPerson: viewedPerson,
                  allPersons: allPersons,
                  allConnections: allConnections,
                  allEvents: const [],
                ),
                child: const Text('open dialog'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open dialog'));
  await tester.pumpAndSettle();
}

Future<void> _selectOtherPerson(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(const Key('add-connection-person-dropdown')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

/// Picks [type] on the relationship-type dropdown by invoking its `onChanged` callback
/// directly, the same callback Flutter calls when a menu item is tapped. The type
/// dropdown lists all 25 [RelationshipType] values, and Flutter's dropdown menu only
/// mounts the items near the current scroll position (it opens scrolled to the
/// currently-selected item), so driving it through the real popup would require
/// scrolling a popup route - brittle and slow. Going through `onChanged` exercises the
/// exact same app code path the popup would (`onChanged: (t) => setState(...)`) without
/// depending on the popup's internal scroll/virtualisation behaviour.
Future<void> _selectType(WidgetTester tester, RelationshipType type) async {
  final dropdown = tester.widget<DropdownButtonFormField<RelationshipType>>(
    find.byKey(const Key('add-connection-type-dropdown')),
  );
  dropdown.onChanged!(type);
  await tester.pumpAndSettle();
}

void main() {
  late FakeDatabaseService db;
  late Person anna;
  late Person bert;

  setUp(() {
    db = FakeDatabaseService();
    anna = Person(id: 'anna', name: 'Anna');
    bert = Person(id: 'bert', name: 'Bert');
  });

  testWidgets('shows a sentence preview for the default type before anyone is picked',
      (tester) async {
    await _pumpDialogHost(tester, db, anna, [anna, bert]);

    expect(find.byKey(const Key('add-connection-sentence-preview')), findsOneWidget);
    // Default type is "friend"; no other person picked yet -> placeholder.
    expect(find.text('Anna is the friend of ….'), findsOneWidget);
  });

  testWidgets('updates the preview to the brief\'s example once Bert and Parent are picked',
      (tester) async {
    await _pumpDialogHost(tester, db, anna, [anna, bert]);

    await _selectOtherPerson(tester, 'Bert');
    await _selectType(tester, RelationshipType.parent);

    expect(find.text('Anna is the parent of Bert.'), findsOneWidget);
  });

  testWidgets('warns (without blocking) when the fact already exists', (tester) async {
    final existing = Connection(person1Id: 'bert', person2Id: 'anna', relationshipType: 'child');
    // "Bert is the child of Anna" == "Anna is the parent of Bert" (same fact, other side).
    await _pumpDialogHost(tester, db, anna, [anna, bert], allConnections: [existing]);

    await _selectOtherPerson(tester, 'Bert');
    await _selectType(tester, RelationshipType.parent);

    expect(find.textContaining('already seems to exist'), findsOneWidget);

    final addButton = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Add'));
    expect(addButton.onPressed, isNull);
  });

  testWidgets('saves the connection with the viewed person as person1 (direction preserved)',
      (tester) async {
    await _pumpDialogHost(tester, db, anna, [anna, bert]);

    await _selectOtherPerson(tester, 'Bert');
    await _selectType(tester, RelationshipType.parent);

    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    expect(db.connections, hasLength(1));
    final saved = db.connections.values.single;
    expect(saved.person1Id, 'anna');
    expect(saved.person2Id, 'bert');
    expect(saved.relationshipType, RelationshipType.parent.storageValue);
  });

  testWidgets('can create a brand-new person by name and connect to them', (tester) async {
    await _pumpDialogHost(tester, db, anna, [anna]);

    await tester.tap(find.byKey(const Key('add-connection-person-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('+ Add new person…').last);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'Clara');
    await tester.pumpAndSettle();

    expect(find.text('Anna is the friend of Clara.'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    expect(db.persons.values.any((p) => p.name == 'Clara'), isTrue);
    expect(db.connections, hasLength(1));
    final saved = db.connections.values.single;
    final newPersonId = db.persons.values.firstWhere((p) => p.name == 'Clara').id;
    expect(saved.person2Id, newPersonId);
  });
}
