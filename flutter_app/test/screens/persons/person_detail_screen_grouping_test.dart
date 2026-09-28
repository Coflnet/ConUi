import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/screens/persons/person_detail_screen.dart';
import 'package:relationship_manager/services/database_service.dart';

import '../support/fake_database_service.dart';

Future<void> _pumpPersonDetail(WidgetTester tester, DatabaseService db, String personId) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<DatabaseService>.value(
      value: db,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PersonDetailScreen(personId: personId),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Adds a connection to [db] keyed by its own id, so `FakeDatabaseService.deleteConnection`
/// (which removes by id) and the screen's `connection.id`-based lookups agree with the
/// map key.
void _addConnection(FakeDatabaseService db, String id, String person1Id, String person2Id, String type) {
  db.connections[id] =
      Connection(id: id, person1Id: person1Id, person2Id: person2Id, relationshipType: type);
}

void main() {
  late FakeDatabaseService db;
  late Person anna;
  late Person karl;
  late Person bert;

  setUp(() {
    db = FakeDatabaseService();
    anna = Person(id: 'anna', name: 'Anna');
    karl = Person(id: 'karl', name: 'Karl');
    bert = Person(id: 'bert', name: 'Bert');
    db.persons.addAll({anna.id: anna, karl.id: karl, bert.id: bert});
  });

  testWidgets('groups a connection under "Children" on the parent\'s page, labelled with their own role',
      (tester) async {
    // Anna is the parent of Bert (stored exactly per the reading rule).
    _addConnection(db, 'c1', anna.id, bert.id, 'parent');

    await _pumpPersonDetail(tester, db, anna.id);

    expect(find.text('Children'), findsOneWidget);
    expect(find.text('Parents'), findsNothing);
    expect(find.text('Bert'), findsOneWidget);
    expect(find.text('Parent of Bert'), findsOneWidget);
  });

  testWidgets('shows the inverse role on the other person\'s page', (tester) async {
    _addConnection(db, 'c1', anna.id, bert.id, 'parent');

    await _pumpPersonDetail(tester, db, bert.id);

    expect(find.text('Parents'), findsOneWidget);
    expect(find.text('Children'), findsNothing);
    expect(find.text('Anna'), findsOneWidget);
    expect(find.text('Child of Anna'), findsOneWidget);
  });

  testWidgets('marks a derived sibling as derived and offers no edit/delete for it', (tester) async {
    _addConnection(db, 'c1', karl.id, anna.id, 'parent');
    _addConnection(db, 'c2', karl.id, bert.id, 'parent');

    await _pumpPersonDetail(tester, db, anna.id);

    expect(find.text('Siblings'), findsOneWidget);
    expect(find.textContaining('derived'), findsOneWidget);
    // The derived entry shows an indicator icon instead of edit/delete actions (karl's
    // own entry, in the Parents section, is a real connection and keeps its edit icon).
    expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
  });

  testWidgets('an explicit (non-derived) connection offers edit and delete actions', (tester) async {
    _addConnection(db, 'c1', anna.id, bert.id, 'friend');

    await _pumpPersonDetail(tester, db, anna.id);

    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
  });

  testWidgets('deleting a connection removes it from the list after confirming', (tester) async {
    _addConnection(db, 'c1', anna.id, bert.id, 'friend');

    await _pumpPersonDetail(tester, db, anna.id);
    expect(find.text('Bert'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('Delete Connection'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(db.connections, isEmpty);
    expect(find.text('Bert'), findsNothing);
  });

  testWidgets('shows no Connections section when there are none', (tester) async {
    await _pumpPersonDetail(tester, db, anna.id);
    expect(find.text('Connections'), findsNothing);
  });
}
