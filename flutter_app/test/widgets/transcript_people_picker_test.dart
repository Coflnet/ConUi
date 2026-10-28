import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/models/person.dart';
import 'package:relationship_manager/models/event.dart';
import 'package:relationship_manager/relationships/relationship_type.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/widgets/transcript_people_picker.dart';

import '../support/localized_app.dart';
import '../support/test_database.dart';

Future<DatabaseService> _database(WidgetTester tester,
    [List<Person> people = const []]) async {
  final db = createTestDatabaseService();
  await tester.runAsync(() async {
    await db.initialize();
    for (final person in people) {
      await db.savePerson(person);
    }
  });
  addTearDown(() => tester.runAsync(() async {
        await (await db.database).close();
        db.dispose();
      }));
  return db;
}

Future<TranscriptPeopleController> _controller(
    WidgetTester tester, DatabaseService db, String initialText) async {
  late TranscriptPeopleController controller;
  await tester.runAsync(() async {
    controller = TranscriptPeopleController(
        TextEditingController(text: initialText), db);
    await controller.peopleForSave();
  });
  addTearDown(() {
    controller.dispose();
    controller.text.dispose();
  });
  return controller;
}

void main() {
  for (final existing in [false, true]) {
    for (final text in [
      'Jana hat einen Hund namens Milo.',
      'Jana has a cat named Milo.',
    ]) {
      testWidgets(
          'pet facts keep their owner and never save a human pet '
          '(existing=$existing, $text)', (tester) async {
        final milo = Person(
            id: 'milo',
            name: 'Milo',
            storyFacts: {'older': 'Existing human fact'});
        final db = await _database(tester, [if (existing) milo]);
        final controller = await _controller(tester, db, text);
        expect(controller.selectedPeople.single.name, 'Jana');
        expect(controller.facts.single.person.name, 'Jana');
        expect(controller.facts.single.sourceText,
            text.substring(0, text.length - 1));
        await tester.pumpWidget(wrapLocalized(
            Scaffold(body: TranscriptPeoplePicker(controller: controller))));
        expect(find.widgetWithText(Chip, 'Jana'), findsOneWidget);
        expect(find.widgetWithText(Chip, 'Milo'), findsNothing);
        await tester.runAsync(() async {
          final ids =
              await saveStoryPeople(db, await controller.peopleForSave());
          final story = Event(
              title: 'Pet',
              dateTime: DateTime(2026, 10, 27),
              participantIds: ids);
          await db.saveEvent(story);
          await controller.saveInformation(story);
          final people = await db.getPersons();
          final jana = people.singleWhere((p) => p.name == 'Jana');
          expect(ids, [jana.id]);
          expect(jana.storyFacts[story.id], text.substring(0, text.length - 1));
          expect(people, hasLength(existing ? 2 : 1));
          if (existing) {
            expect((await db.getPerson(milo.id))!.storyFacts, milo.storyFacts);
          }
        });
        controller.text.text = '$text Herr Milo kam.';
        expect(controller.selectedPeople.map((p) => p.name), ['Jana', 'Milo']);
        if (existing) expect(controller.selectedPeople.last.id, milo.id);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  for (final existing in [false, true]) {
    testWidgets('residence facts save with their person (existing=$existing)',
        (tester) async {
      final john = Person(
          id: 'john',
          name: 'John',
          address: 'Previous address',
          company: 'Previous company',
          storyFacts: {'older': 'Previous fact'});
      final alex = Person(
          id: 'alex',
          name: 'Alex',
          address: 'Other address',
          company: 'Other company',
          storyFacts: {'older': 'Other fact'});
      final db = await _database(tester, [if (existing) john, alex]);
      final controller = await _controller(
          tester, db, 'John wohnt in der Dorfstraße 17. John works at Zeta.');
      expect(controller.selectedPeople.single.name, 'John');
      expect(
          controller.facts.map((fact) => fact.person.name), ['John', 'John']);
      if (existing) expect(controller.selectedPeople.single.id, john.id);
      await tester.runAsync(() async {
        expect((await db.getPerson(alex.id))!.storyFacts, alex.storyFacts);
        final ids = await saveStoryPeople(db, await controller.peopleForSave());
        final event = Event(
            title: 'Residence',
            dateTime: DateTime(2026, 10, 26),
            participantIds: ids);
        await db.saveEvent(event);
        await controller.saveInformation(event);
        final people = await db.getPersons();
        expect(people, hasLength(2));
        final savedJohn = people.singleWhere((person) => person.name == 'John');
        expect(event.participantIds, [savedJohn.id]);
        expect(savedJohn.storyFacts[event.id],
            'John wohnt in der Dorfstraße 17\nJohn works at Zeta');
        expect(savedJohn.address, existing ? 'Previous address' : isNull);
        expect(savedJohn.company, existing ? 'Previous company' : 'Zeta');
        if (existing) expect(savedJohn.storyFacts['older'], 'Previous fact');
        final savedAlex = await db.getPerson(alex.id);
        expect(savedAlex!.address, alex.address);
        expect(savedAlex.company, alex.company);
        expect(savedAlex.storyFacts, alex.storyFacts);
        expect(await db.getPlaces(), isEmpty);
      });
    });
  }

  for (final existing in [false, true]) {
    testWidgets(
        'German possessive endpoints survive review and save (existing=$existing)',
        (tester) async {
      final ben = Person(id: 'ben', name: 'Ben');
      final hans = Person(id: 'hans', name: 'Hans');
      final alex = Person(id: 'alex', name: 'Alex');
      for (final (text, owner) in [
        ('Bens Vater ist Alex.', 'Ben'),
        ('Alex ist Bens Vater.', 'Ben'),
        ('Hans’ Vater ist Alex.', 'Hans'),
        ("Alex ist Hans' Vater.", 'Hans'),
      ]) {
        final db = await _database(tester, existing ? [ben, hans, alex] : []);
        final controller = await _controller(tester, db, text);
        expect(controller.selectedPeople.map((p) => p.name),
            unorderedEquals([owner, 'Alex']),
            reason: text);
        final connection = controller.connections.single;
        expect((
          connection.person1.name,
          connection.type,
          connection.person2.name
        ), (
          'Alex',
          RelationshipType.parent,
          owner
        ), reason: text);
        expect(connection.sourceText, text.substring(0, text.length - 1));
        if (existing) {
          expect(connection.person2.id, owner == 'Ben' ? ben.id : hans.id);
        }
        await tester.runAsync(() async {
          final ids =
              await saveStoryPeople(db, await controller.peopleForSave());
          final event = Event(
              title: text,
              dateTime: DateTime(2026, 10, 26),
              participantIds: ids);
          await db.saveEvent(event);
          await controller.saveInformation(event);
          expect(await db.getConnectionsForEvent(event.id), hasLength(1));
        });
      }
    });
  }

  testWidgets('full relative chain previews new people and writes only on Save',
      (tester) async {
    final db = await _database(tester);
    final controller = await _controller(
        tester,
        db,
        'Alex got a new car. Alex is the brother of Ben, who works at Zeta '
        'and is a colleague of Dana.');
    expect(controller.selectedPeople.map((p) => p.name),
        unorderedEquals(['Alex', 'Ben', 'Dana']));
    expect(
        controller.connections
            .map((c) => (c.person1.name, c.type, c.person2.name)),
        [
          ('Alex', RelationshipType.sibling, 'Ben'),
          ('Ben', RelationshipType.colleague, 'Dana'),
        ]);
    expect(controller.facts.map((f) => (f.person.name, f.value, f.isCompany)), [
      ('Alex', 'Alex got a new car', false),
      ('Ben', 'Zeta', true),
    ]);
    await tester.pumpWidget(wrapLocalized(
        Scaffold(body: TranscriptPeoplePicker(controller: controller))));
    expect(find.widgetWithText(Chip, 'Zeta'), findsNothing);
    expect(find.byIcon(Icons.person_add_alt_1), findsNWidgets(3));
    expect(find.byIcon(Icons.link), findsNWidgets(2));
    expect(find.byIcon(Icons.business), findsOneWidget);
    await tester.runAsync(() async {
      expect(await db.getPersons(), isEmpty);
      expect(await db.getConnections(), isEmpty);
      expect(await db.getPendingChanges(), isEmpty);
      final ids = await saveStoryPeople(db, await controller.peopleForSave());
      final event = Event(
          title: 'Story', dateTime: DateTime(2026, 10, 4), participantIds: ids);
      await db.saveEvent(event);
      await controller.saveInformation(event);
      final people = await db.getPersons();
      expect(
          people.map((p) => p.name), unorderedEquals(['Alex', 'Ben', 'Dana']));
      expect(people.singleWhere((p) => p.name == 'Ben').company, 'Zeta');
      expect(people.singleWhere((p) => p.name == 'Alex').storyFacts[event.id],
          'Alex got a new car');
      expect(await db.getConnectionsForEvent(event.id), hasLength(2));
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('German relative chain uses Ben for employer and colleague',
      (tester) async {
    final db = await _database(tester);
    final controller = await _controller(
        tester,
        db,
        'Alex hat ein neues Auto. Alex ist der Bruder von Ben, der bei Zeta '
        'arbeitet und ein Kollege von Dana ist.');
    expect(controller.selectedPeople.map((p) => p.name),
        unorderedEquals(['Alex', 'Ben', 'Dana']));
    expect(controller.connections.last.person1.name, 'Ben');
    expect(controller.connections.last.person2.name, 'Dana');
    expect(controller.facts.singleWhere((f) => f.isCompany).person.name, 'Ben');
  });

  testWidgets('dismissed information stays dismissed through reload and tail',
      (tester) async {
    final db = await _database(tester);
    const head = 'Alex got a new car. Alex is the brother of Ben. '
        'Ben works at Zeta.';
    final controller = await _controller(tester, db, head);
    await tester.pumpWidget(wrapLocalized(
        Scaffold(body: TranscriptPeoplePicker(controller: controller))));
    final relationshipRow = find.ancestor(
        of: find.byIcon(Icons.link), matching: find.byType(ListTile));
    await tester.tap(find.descendant(
        of: relationshipRow, matching: find.byType(IconButton)));
    final companyRow = find.ancestor(
        of: find.byIcon(Icons.business), matching: find.byType(ListTile));
    await tester.tap(
        find.descendant(of: companyRow, matching: find.byType(IconButton)));
    await tester.pump();
    expect(controller.connections, isEmpty);
    expect(controller.facts.single.isCompany, isFalse);
    controller.text.text = '$head Ben is a colleague of Dana.';
    await tester.runAsync(() async {
      await controller.peopleForSave();
    });
    await tester.pump();
    expect(controller.connections.single.type, RelationshipType.colleague);
    expect(controller.facts.single.person.name, 'Alex');
    expect(find.byIcon(Icons.business), findsNothing);
    await tester.runAsync(() async {
      expect(await db.getPersons(), isEmpty);
      expect(await db.getPendingChanges(), isEmpty);
      final ids = await saveStoryPeople(db, await controller.peopleForSave());
      final story = Event(
          title: 'Reviewed',
          dateTime: DateTime(2026, 10, 4),
          participantIds: ids);
      await db.saveEvent(story);
      await controller.saveInformation(story);
      expect(
          (await db.getConnectionsForEvent(story.id)).single.relationshipType,
          'colleague');
      final ben = (await db.getPersons()).singleWhere((p) => p.name == 'Ben');
      expect(ben.company, isNull);
      expect(ben.storyFacts.containsKey(story.id), isFalse);
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'removing a person removes their incident relationships and facts',
      (tester) async {
    final db = await _database(tester);
    final controller = await _controller(
        tester,
        db,
        'Alex is the brother of Ben, who works at Zeta and is a colleague '
        'of Dana. Alex bought a new car.');
    controller.dismiss('Ben');
    expect(controller.selectedPeople.map((p) => p.name),
        unorderedEquals(['Alex', 'Dana']));
    expect(controller.connections, isEmpty);
    expect(controller.facts.single.person.name, 'Alex');
    await tester.runAsync(() async {
      await controller.peopleForSave();
      expect(controller.connections, isEmpty);
      expect(controller.facts.single.person.name, 'Alex');
      expect(await db.getPersons(), isEmpty);
    });
  });

  testWidgets('ambiguous relationship endpoint requires the widget choice',
      (tester) async {
    final first = Person(id: 'first', name: 'Paul Müller');
    final second = Person(id: 'second', name: 'Paul Schmidt');
    final db = await _database(tester, [first, second]);
    final controller = await _controller(
        tester, db, 'Paul is the father of Ben. Paul works at Zeta.');
    expect(controller.connections, isEmpty);
    expect(controller.facts, isEmpty);
    expect(controller.selectedPeople.single.name, 'Ben');
    await tester.pumpWidget(wrapLocalized(
        Scaffold(body: TranscriptPeoplePicker(controller: controller))));
    await tester.tap(find.widgetWithText(ActionChip, second.name));
    await tester.pump();
    expect(controller.connections.single.person1.id, 'second');
    expect(controller.connections.single.person2.name, 'Ben');
    expect(controller.facts.single.person.id, 'second');
    await tester.runAsync(() async {
      await controller.peopleForSave();
      expect(controller.connections.single.person1.id, 'second');
      expect(await db.getPersons(), hasLength(2));
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'new directional roles require a choice and share inverse story evidence',
      (tester) async {
    final first = Person(id: 'first', name: 'Paul Müller');
    final second = Person(id: 'second', name: 'Paul Schmidt');
    final db = await _database(tester, [first, second]);
    const text = 'Paul is the teacher of Ben. '
        'Paul ist der Arbeitgeber von Ben. Paul is the manager of Ben.';
    final controller = await _controller(tester, db, text);
    expect(controller.connections, isEmpty);
    expect(controller.selectedPeople.single.name, 'Ben');
    await tester.pumpWidget(wrapLocalized(
        Scaffold(body: TranscriptPeoplePicker(controller: controller))));
    await tester.tap(find.widgetWithText(ActionChip, second.name));
    await tester.pump();
    expect(
        controller.connections
            .map((c) => (c.person1.id, c.type, c.person2.name)),
        [
          ('second', RelationshipType.teacher, 'Ben'),
          ('second', RelationshipType.employer, 'Ben'),
          ('second', RelationshipType.manager, 'Ben'),
        ]);
    final story = Event(title: 'Roles', dateTime: DateTime(2026, 10, 27));
    late String benId;
    late Map<String, String> connectionIds;
    await tester.runAsync(() async {
      expect(await db.getConnections(), isEmpty);
      expect(await db.getPersons(), hasLength(2));
      final ids = await saveStoryPeople(db, await controller.peopleForSave());
      benId = ids.singleWhere((id) => id != second.id);
      await db.saveEvent(story.copyWith(participantIds: ids));
      await controller.saveInformation(story);
      final saved = await db.getConnectionsForEvent(story.id);
      connectionIds = {
        for (final edge in saved) edge.relationshipType: edge.id
      };
      expect(connectionIds.keys,
          unorderedEquals(['teacher', 'employer', 'manager']));
      expect(saved.map((edge) => edge.description),
          unorderedEquals(text.substring(0, text.length - 1).split('. ')));
      for (final edge in saved) {
        expect((edge.person1Id, edge.person2Id), (second.id, benId));
        expect(edge.isInferred, isTrue);
        expect(edge.sourceEventIds, [story.id]);
      }
    });
    await tester.pumpWidget(const SizedBox.shrink());

    final inverse = await _controller(
        tester,
        db,
        'Ben ist der Schüler von Paul Schmidt. '
        'Ben is the employee of Paul Schmidt. Ben berichtet an Paul Schmidt.');
    expect(
        inverse.connections.map((c) => (c.person1.id, c.type, c.person2.id)), [
      (benId, RelationshipType.student, second.id),
      (benId, RelationshipType.employee, second.id),
      (benId, RelationshipType.directReport, second.id),
    ]);
    await tester.runAsync(() async {
      final ids = await saveStoryPeople(db, await inverse.peopleForSave());
      expect(ids, unorderedEquals([benId, second.id]));
      final other = Event(
          title: 'Inverse roles',
          dateTime: DateTime(2026, 10, 28),
          participantIds: ids);
      await db.saveEvent(other);
      await inverse.saveInformation(other);
      expect(await db.getPersons(), hasLength(3));
      final saved = await db.getConnections();
      expect(saved, hasLength(3));
      expect((await db.getConnectionsForEvent(other.id)).map((edge) => edge.id),
          unorderedEquals(connectionIds.values));
      expect(saved.map((edge) => edge.description),
          unorderedEquals(text.substring(0, text.length - 1).split('. ')));
      for (final edge in saved) {
        expect(edge.id, connectionIds[edge.relationshipType]);
        expect((edge.person1Id, edge.person2Id), (second.id, benId));
        expect(edge.originEventId, story.id);
        expect(edge.sourceEventIds, [story.id, other.id]);
      }
    });
  });

  testWidgets('relationship aliases reuse canonical people and deduplicate',
      (tester) async {
    final anna = Person(id: 'anna', name: 'Anna Müller', aliases: ['Änni']);
    final ben = Person(id: 'ben', name: 'Ben Schmidt');
    final db = await _database(tester, [anna, ben]);
    final controller = await _controller(
        tester,
        db,
        'Änni is the sister of Ben. Ben Schmidt is the brother of Anna Müller. '
        'Änni works at Zeta.');
    expect(controller.selectedPeople.map((p) => p.id),
        unorderedEquals(['anna', 'ben']));
    expect(controller.connections, hasLength(1));
    expect(controller.connections.single.person1.id, 'anna');
    expect(controller.connections.single.person2.id, 'ben');
    expect(controller.facts.single.person.id, 'anna');
    await tester.runAsync(() async {
      final ids = await saveStoryPeople(db, await controller.peopleForSave());
      expect(ids, unorderedEquals(['anna', 'ben']));
      expect(await db.getPersons(), hasLength(2));
    });
  });

  testWidgets('text edits remove proposed information and saved story evidence',
      (tester) async {
    final db = await _database(tester);
    final controller = await _controller(
        tester, db, 'Alex is a friend of Ben. Alex bought a new car.');
    await tester.runAsync(() async {
      final ids = await saveStoryPeople(db, await controller.peopleForSave());
      final story = Event(
          title: 'Editable',
          dateTime: DateTime(2026, 10, 4),
          participantIds: ids);
      await db.saveEvent(story);
      await controller.saveInformation(story);
      expect(await db.getConnectionsForEvent(story.id), hasLength(1));
      controller.text.text = 'A story without this information.';
      await controller.peopleForSave();
      expect(controller.connections, isEmpty);
      expect(controller.facts, isEmpty);
      expect(controller.selectedPeople, isEmpty);
      await controller.saveInformation(story);
      expect(await db.getConnectionsForEvent(story.id), isEmpty);
      expect(
          (await db.getPersons())
              .every((p) => !p.storyFacts.containsKey(story.id)),
          isTrue);
    });
  });

  testWidgets(
      'unfamiliar full name does not select a known first-name collision',
      (tester) async {
    final known = Person(id: 'existing', name: 'Anna Müller');
    final db = await _database(tester, [known]);
    final controller = await _controller(tester, db,
        'Anna Schmidt is the sister of Ben. Anna Schmidt bought a new car.');
    expect(controller.selectedPeople.map((p) => p.name),
        unorderedEquals(['Anna Schmidt', 'Ben']));
    expect(controller.selectedPeople.any((p) => p.id == known.id), isFalse);
    expect(controller.connections.single.person1.name, 'Anna Schmidt');
    expect(controller.connections.single.person1.id, isNot(known.id));
    expect(controller.facts.single.person.name, 'Anna Schmidt');
    await tester.runAsync(() async {
      expect((await controller.peopleForSave()).map((p) => p.name),
          unorderedEquals(['Anna Schmidt', 'Ben']));
      expect(await db.getPersons(), hasLength(1));
    });
  });

  testWidgets('current typed and final text determines participants',
      (tester) async {
    final anna = Person(id: 'anna', name: 'Anna Müller');
    final paul = Person(id: 'paul', name: 'Paul Schmidt');
    final db = await _database(tester, [anna, paul]);
    final controller = await _controller(tester, db, 'Anna Müller war dabei.');
    expect(controller.selectedPeople.map((p) => p.id), ['anna']);

    controller.text.text = 'Paul Schmidt war dabei.';
    expect(controller.selectedPeople.map((p) => p.id), ['paul']);
    controller.text.text = 'Eine Geschichte ohne Personen.';
    await tester.runAsync(() async {
      expect(await controller.peopleForSave(), isEmpty);
    });
  });

  testWidgets('removing a draft chip dismisses later fuller transcript names',
      (tester) async {
    final db = await _database(tester);
    final controller = await _controller(tester, db, 'Meine Schwester Anna');
    await tester.pumpWidget(wrapLocalized(
        Scaffold(body: TranscriptPeoplePicker(controller: controller))));
    expect(find.widgetWithText(Chip, 'Anna'), findsOneWidget);
    tester.widget<Chip>(find.widgetWithText(Chip, 'Anna')).onDeleted!();
    await tester.pump();
    expect(controller.selectedPeople, isEmpty);

    controller.text.text =
        'Meine Schwester Anna Müller kam. Onkel Paul kam auch.';
    await tester.pump();
    expect(controller.selectedPeople.map((p) => p.name), ['Paul']);
    expect(find.widgetWithText(Chip, 'Anna Müller'), findsNothing);
    await tester.runAsync(() async {
      expect(await db.getPersons(), isEmpty);
      expect(await db.getPendingChanges(), isEmpty);
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('shared first names require an explicit action chip choice',
      (tester) async {
    final paul = Person(id: 'paul', name: 'Paul Müller');
    final otherPaul = Person(id: 'other', name: 'Paul Schmidt');
    final db = await _database(tester, [paul, otherPaul]);
    final controller = await _controller(tester, db, 'Paul kam mit.');
    await tester.pumpWidget(wrapLocalized(
        Scaffold(body: TranscriptPeoplePicker(controller: controller))));
    expect(controller.selectedPeople, isEmpty);
    expect(find.widgetWithText(ActionChip, paul.name), findsOneWidget);
    expect(find.widgetWithText(ActionChip, otherPaul.name), findsOneWidget);

    await tester.tap(find.widgetWithText(ActionChip, otherPaul.name));
    await tester.pump();
    expect(controller.selectedPeople.map((p) => p.id), ['other']);
    expect(find.widgetWithText(Chip, otherPaul.name), findsOneWidget);
    expect(find.byType(ActionChip), findsNothing);
    await tester.runAsync(() async {
      expect((await controller.peopleForSave()).map((p) => p.id), ['other']);
      expect(await db.getPersons(), hasLength(2));
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('aliases reuse the existing ID without creating another person',
      (tester) async {
    final anna = Person(id: 'anna', name: 'Anna Müller', aliases: ['Änni']);
    final db = await _database(tester, [anna]);
    final controller =
        await _controller(tester, db, 'Änni und Anna Müller kamen.');
    expect(controller.selectedPeople.map((p) => p.id), ['anna']);
    await tester.runAsync(() async {
      final ids = await saveStoryPeople(db, await controller.peopleForSave());
      expect(ids, ['anna']);
      expect(await db.getPersons(), hasLength(1));
      expect(await db.getPendingChanges(), hasLength(1));
    });
  });

  testWidgets('draft recognition and save preparation do not write to the DB',
      (tester) async {
    final db = await _database(tester);
    final controller =
        await _controller(tester, db, 'My sister Jane Smith arrived.');
    expect(controller.selectedPeople.single.name, 'Jane Smith');
    await tester.runAsync(() async {
      expect((await controller.peopleForSave()).single.name, 'Jane Smith');
      expect(await db.getPersons(), isEmpty);
      expect(await db.getPendingChanges(), isEmpty);
    });
    controller.text.clear();
    expect(controller.selectedPeople, isEmpty);
    await tester.runAsync(() async {
      expect(await db.getPersons(), isEmpty);
      expect(await db.getPendingChanges(), isEmpty);
    });
  });

  testWidgets('discarding the form leaves no people or pending writes',
      (tester) async {
    final db = await _database(tester);
    final text = TextEditingController(text: 'My sister Jane Smith arrived.');
    late TranscriptPeopleController controller;
    await tester.runAsync(() async {
      controller = TranscriptPeopleController(text, db);
      expect((await controller.peopleForSave()).single.name, 'Jane Smith');
    });
    controller.dispose();
    text.dispose();
    await tester.runAsync(() async {
      expect(await db.getPersons(), isEmpty);
      expect(await db.getPendingChanges(), isEmpty);
    });
  });

  testWidgets(
      'save deduplicates differently spelled draft names and writes once',
      (tester) async {
    final db = await _database(tester);
    await tester.runAsync(() async {
      final ids = await saveStoryPeople(db, [
        Person(name: 'Jane Smith'),
        Person(name: '  JANE   SMITH '),
      ]);
      expect(ids, hasLength(1));
      final saved = await db.getPersons();
      expect(saved.single.id, ids.single);
      expect(saved.single.name, 'Jane Smith');
      expect(await db.getPendingChanges(), hasLength(1));
    });
  });

  testWidgets('person saved while form is open replaces draft at final save',
      (tester) async {
    final db = await _database(tester);
    final controller =
        await _controller(tester, db, 'My sister Jane Smith arrived.');
    final draft = controller.selectedPeople.single;
    final known = Person(id: 'known-jane', name: 'Jane Smith');
    await tester.runAsync(() async {
      await db.savePerson(known);
      final latest = await controller.peopleForSave();
      expect(latest.single.id, known.id);
      expect(latest.single.id, isNot(draft.id));
      // Even callers holding an earlier draft reuse the new record.
      expect(await saveStoryPeople(db, [draft]), [known.id]);
      expect(await db.getPersons(), hasLength(1));
      expect(await db.getPendingChanges(), hasLength(1));
    });
  });

  testWidgets('manual selections hide duplicate recognized chips',
      (tester) async {
    final anna = Person(id: 'anna', name: 'Anna Müller');
    final db = await _database(tester, [anna]);
    final controller =
        await _controller(tester, db, 'Anna Müller traf Onkel Paul.');
    await tester.pumpWidget(wrapLocalized(Scaffold(
        body: TranscriptPeoplePicker(
            controller: controller,
            selectedIds: const {'anna'},
            selectedNames: const {'paul'}))));
    expect(find.byType(Chip), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
