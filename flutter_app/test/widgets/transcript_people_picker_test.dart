import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/models/person.dart';
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
