import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/screens/persons/relationship_graph_screen.dart';
import 'package:relationship_manager/services/database_service.dart';

import '../support/fake_database_service.dart';

void _addConnection(
    FakeDatabaseService db, String id, String person1Id, String person2Id, String type) {
  db.connections[id] =
      Connection(id: id, person1Id: person1Id, person2Id: person2Id, relationshipType: type);
}

Future<void> _pumpGraph(WidgetTester tester, DatabaseService db, String centerId) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<DatabaseService>.value(
      value: db,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RelationshipGraphScreen(centerPersonId: centerId),
      ),
    ),
  );
  await tester.pumpAndSettle();
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
    // Karl is Anna's parent; Anna and Bert are partners.
    _addConnection(db, 'c1', karl.id, anna.id, 'parent');
    _addConnection(db, 'c2', anna.id, bert.id, 'partner');
  });

  testWidgets('shows the centered person\'s name in the app bar and draws the reachable nodes',
      (tester) async {
    await _pumpGraph(tester, db, anna.id);

    expect(find.text("Anna's family graph"), findsOneWidget);
    expect(find.text('Anna'), findsOneWidget);
    expect(find.text('Karl'), findsOneWidget);
    expect(find.text('Bert'), findsOneWidget);
  });

  testWidgets('tapping a node opens a sheet with center/open/add actions', (tester) async {
    await _pumpGraph(tester, db, anna.id);

    await tester.tap(find.text('Karl'));
    await tester.pumpAndSettle();

    expect(find.text('Center graph on this person'), findsOneWidget);
    expect(find.text('Open person'), findsOneWidget);
    expect(find.text('Add relationship from Karl'), findsOneWidget);
  });

  testWidgets('centering on another person re-runs the layout with them in the middle',
      (tester) async {
    await _pumpGraph(tester, db, anna.id);

    await tester.tap(find.text('Karl'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Center graph on this person'));
    await tester.pumpAndSettle();

    expect(find.text("Karl's family graph"), findsOneWidget);
  });

  testWidgets('the "center on this person" action is disabled for the already-centered node',
      (tester) async {
    await _pumpGraph(tester, db, anna.id);

    await tester.tap(find.text('Anna'));
    await tester.pumpAndSettle();

    final tile = tester.widget<ListTile>(find.widgetWithText(ListTile, 'Center graph on this person'));
    expect(tile.enabled, isFalse);
  });

  testWidgets('the text-alternative toggle lists the same relationships as sentences',
      (tester) async {
    await _pumpGraph(tester, db, anna.id);

    await tester.tap(find.byTooltip('Show as list'));
    await tester.pumpAndSettle();

    expect(find.textContaining('is the parent of'), findsOneWidget);
    expect(find.textContaining('are partners'), findsOneWidget);
  });

  testWidgets('shows a placeholder when the person has no relationships', (tester) async {
    final solo = Person(id: 'solo', name: 'Solo');
    db.persons[solo.id] = solo;

    await _pumpGraph(tester, db, solo.id);

    expect(find.text('No relationships to show yet.'), findsOneWidget);
  });
}
