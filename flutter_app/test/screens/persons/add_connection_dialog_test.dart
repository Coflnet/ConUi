import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/relationships/relationship_type.dart';
import 'package:relationship_manager/screens/persons/add_connection_dialog.dart';
import 'package:relationship_manager/screens/persons/edit_connection_dialog.dart';
import 'package:relationship_manager/services/database_service.dart';

import '../support/fake_database_service.dart';

class _FailConnectionOnce extends FakeDatabaseService {
  bool fail = true;
  @override
  Future<void> saveConnection(Connection connection, {bool recordPendingChange = true}) async {
    if (fail) { fail = false; throw StateError('disk unavailable'); }
    await super.saveConnection(connection);
  }
}

Future<void> _pumpDialogHost(
  WidgetTester tester,
  DatabaseService db,
  Person viewedPerson,
  List<Person> allPersons, {
  List<Connection> allConnections = const [],
  List<Event> allEvents = const [],
  Event? initialEvent,
  Connection? editing,
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
                onPressed: () => editing != null ? showEditConnectionDialog(context,
                  connection: editing, viewedPerson: viewedPerson,
                  otherPerson: allPersons.firstWhere((person) => person.id != viewedPerson.id)) : showAddConnectionDialog(
                  context,
                  viewedPerson: viewedPerson,
                  allPersons: allPersons,
                  allConnections: allConnections,
                  allEvents: allEvents,
                  initialEvent: initialEvent,
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
    SharedPreferences.setMockInitialValues({});
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

  testWidgets('blocks a duplicate fact without a new story link',
      (tester) async {
    final existing = Connection(
        person1Id: 'bert', person2Id: 'anna', relationshipType: 'child');
    // "Bert is the child of Anna" == "Anna is the parent of Bert" (same fact, other side).
    await _pumpDialogHost(tester, db, anna, [anna, bert], allConnections: [existing]);

    await _selectOtherPerson(tester, 'Bert');
    await _selectType(tester, RelationshipType.parent);

    expect(find.textContaining('already seems to exist'), findsOneWidget);

    final addButton =
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));
    expect(addButton.onPressed, isNull);
  });

  testWidgets(
      'links another story to an inverse fact while preserving its metadata',
      (tester) async {
    final existing = Connection(
        id: 'existing',
        person1Id: 'bert',
        person2Id: 'anna',
        relationshipType: 'child',
        originEventId: 'birth',
        sourceEventIds: ['first-story'],
        description: 'Known family',
        startDate: DateTime(1850),
        endDate: DateTime(1900),
        isInferred: true);
    db.connections[existing.id] = existing;
    final story = Event(
        id: 'another-story', title: 'Another memory', dateTime: DateTime(1870));
    await _pumpDialogHost(tester, db, anna, [anna, bert],
        allConnections: [existing], initialEvent: story);
    await _selectOtherPerson(tester, 'Bert');
    await _selectType(tester, RelationshipType.parent);
    expect(
        find.text(
            'Link this story to the existing relationship without changing it.'),
        findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(db.connections, hasLength(1));
    final saved = db.connections.values.single;
    final expected = existing.toJson()..remove('updatedAt');
    expected['sourceEventIds'] = ['first-story', story.id];
    expect(saved.toJson()..remove('updatedAt'), expected);
    expect(await db.getConnectionsForEvent(story.id), [saved]);
  });

  testWidgets('blocks linking a story already attached as origin or source',
      (tester) async {
    final story =
        Event(id: 'story', title: 'Known story', dateTime: DateTime(2020));
    for (final isOrigin in [true, false]) {
      final existing = Connection(
          person1Id: 'anna',
          person2Id: 'bert',
          relationshipType: 'friend',
          originEventId: isOrigin ? story.id : null,
          sourceEventIds: isOrigin ? [] : [story.id]);
      await _pumpDialogHost(tester, db, anna, [anna, bert],
          allConnections: [existing], initialEvent: story);
      await _selectOtherPerson(tester, 'Bert');
      expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
              .onPressed,
          isNull);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
    }
  });

  testWidgets(
      'saves the connection with the viewed person as person1 (direction preserved)',
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

  testWidgets('can link an existing relationship to a new story with a required title',
      (tester) async {
    final existing = Connection(person1Id: 'anna', person2Id: 'bert', relationshipType: 'friend');
    db.connections[existing.id] = existing;
    await _pumpDialogHost(tester, db, anna, [anna, bert], allConnections: [existing]);
    await _selectOtherPerson(tester, 'Bert');
    await tester.ensureVisible(find.byType(SwitchListTile));
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    final createButton = find.text('Or create new story');
    await tester.ensureVisible(createButton);
    await tester.tap(createButton);
    await tester.pumpAndSettle();
    final saveButton = find.widgetWithText(FilledButton, 'Save');
    expect(tester.widget<FilledButton>(saveButton).onPressed, isNull);
    final titleField = find.widgetWithText(TextField, 'New Story Title');
    await tester.ensureVisible(titleField);
    await tester.enterText(titleField, 'A shared memory');
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
    await tester.pumpAndSettle();
    expect(db.connections, hasLength(1));
    final story = db.events.values.single;
    expect(story.title, 'A shared memory');
    expect(story.participantIds, ['anna', 'bert']);
    expect(db.connections.values.single.sourceEventIds, [story.id]);
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
  testWidgets('partial save retry reuses the newly created person and connection', (tester) async {
    db = _FailConnectionOnce();
    await _pumpDialogHost(tester, db, anna, [anna]);
    await tester.tap(find.byKey(const Key('add-connection-person-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('+ Add new person…').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Clara');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(db.persons, hasLength(1));
    expect(find.text('Could not save your changes. They are still here. Try again.'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(db.persons, hasLength(1));
    expect(db.connections, hasLength(1));
  });

  testWidgets('Cancel keeps editing or saves a draft that restores the relationship', (tester) async {
    await _pumpDialogHost(tester, db, anna, [anna, bert]);
    await _selectOtherPerson(tester, 'Bert');
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('Anna is the friend of Bert.'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save draft'));
    await tester.pumpAndSettle();
    expect(db.connections, isEmpty);
    await tester.tap(find.text('open dialog'));
    await tester.pumpAndSettle();
    expect(find.text('Anna is the friend of Bert.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(db.connections, hasLength(1));
  });

  testWidgets('editing retries a failed save while retaining notes and provenance', (tester) async {
    db = _FailConnectionOnce();
    final connection = Connection(id: 'edge', person1Id: anna.id, person2Id: bert.id,
      relationshipType: 'friend', sourceEventIds: ['story'], description: 'Original');
    db.connections[connection.id] = connection;
    await _pumpDialogHost(tester, db, anna, [anna, bert], editing: connection);
    await tester.enterText(find.byType(TextField), 'Edited notes');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.widgetWithText(TextField, 'Edited notes'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(db.connections, hasLength(1));
    expect(db.connections['edge']!.description, 'Edited notes');
    expect(db.connections['edge']!.sourceEventIds, ['story']);
  });

}
