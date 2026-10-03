import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/relationships/relationship_type.dart';
import 'package:relationship_manager/screens/events/event_detail_screen.dart';
import 'package:relationship_manager/services/database_service.dart';

import 'support/fake_database_service.dart';

Future<void> _openStory(
    WidgetTester tester, FakeDatabaseService db, Event story) async {
  db.events[story.id] = story;
  await tester.pumpWidget(ChangeNotifierProvider<DatabaseService>.value(
    value: db,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: EventDetailScreen(eventId: story.id),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byKey(const Key('story-add-relationship')));
  await tester.tap(find.byKey(const Key('story-add-relationship')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'saves a relationship from a story with its participant and provenance',
      (tester) async {
    final db = FakeDatabaseService();
    db.persons['anna'] = Person(id: 'anna', name: 'Anna');
    db.persons['bert'] = Person(id: 'bert', name: 'Bert');
    final story = Event(
        id: 'story',
        title: 'At the lake',
        dateTime: DateTime(1852, 6, 1),
        participantIds: ['anna']);
    await _openStory(tester, db, story);

    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue);
    expect(find.textContaining('At the lake'), findsWidgets);
    // Historical stories must also be valid initial dates for the date picker.
    await tester.tap(find.text('Start Date'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add-connection-person-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bert').last);
    await tester.pumpAndSettle();
    tester
        .widget<DropdownButtonFormField<RelationshipType>>(
            find.byKey(const Key('add-connection-type-dropdown')))
        .onChanged!(RelationshipType.sibling);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    final saved = db.connections.values.single;
    expect(saved.person1Id, 'anna');
    expect(saved.person2Id, 'bert');
    expect(saved.relationshipType, 'sibling');
    expect(saved.originEventId, story.id);
    expect(saved.startDate, story.dateTime);
    expect(find.text('Anna is the sibling of Bert.'), findsOneWidget);
    expect(
        find.text(
            'Save relationships separately so you can find them again under each person.'),
        findsNothing);
  });

  testWidgets(
      'a story without participants lets the user choose an existing person',
      (tester) async {
    final db = FakeDatabaseService();
    db.persons['anna'] = Person(id: 'anna', name: 'Anna');
    db.persons['bert'] = Person(id: 'bert', name: 'Bert');
    await _openStory(tester, db,
        Event(title: 'A remembered story', dateTime: DateTime(2020)));
    expect(
        find.text('Whose relationship would you like to add?'), findsOneWidget);
    await tester.tap(find.text('Bert'));
    await tester.pumpAndSettle();
    expect(find.text('Bert is the friend of ….'), findsOneWidget);
  });
}
