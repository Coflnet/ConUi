import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/relationships/relationship_type.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/transcript_connection_store.dart';

import '../support/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DatabaseService db;
  late Person ada;
  late Person bob;
  late Event story;

  setUp(() async {
    db = createTestDatabaseService();
    ada = Person(name: 'Ada', aliases: ['Mama']);
    bob = Person(name: 'Bob');
    story = Event(title: 'Recording', dateTime: DateTime(2026, 10, 4));
    await db.savePerson(ada);
    await db.savePerson(bob);
    await db.saveEvent(story);
  });

  test('resolved identities create one inferred edge and retries do no writes',
      () async {
    final candidates = [
      (
        person1: ada,
        person2: bob,
        type: RelationshipType.parent,
        sourceText: 'Mama is Bob’s mother.'
      ),
      (
        person1: bob,
        person2: ada,
        type: RelationshipType.child,
        sourceText: 'Bob is her son.'
      ),
      (
        person1: ada,
        person2: ada,
        type: RelationshipType.friend,
        sourceText: 'Self'
      ),
    ];
    await saveTranscriptInformation(db, story, candidates, []);
    final edge = (await db.getConnections()).single;
    expect(edge.person1Id, ada.id);
    expect(edge.relationshipType, 'parent');
    expect(edge.isInferred, isTrue);
    expect(edge.originEventId, story.id);
    expect(edge.sourceEventIds, [story.id]);
    expect(edge.startDate, story.dateTime);
    expect(edge.description, 'Mama is Bob’s mother.');
    final pending = (await db.getPendingChanges()).length;
    final json = edge.toJson();
    await saveTranscriptInformation(db, story, candidates, []);
    expect((await db.getConnections()).single.toJson(), json);
    expect((await db.getPendingChanges()).length, pending);
  });

  test('manual inverse duplicate keeps all explicit data through source edits',
      () async {
    final explicit = Connection(
      person1Id: bob.id,
      person2Id: ada.id,
      relationshipType: 'child',
      originEventId: 'manual-origin',
      description: 'Known family relation',
      startDate: DateTime(2000),
      endDate: DateTime(2001),
    );
    await db.saveConnection(explicit);
    await saveTranscriptInformation(db, story, [
      (
        person1: ada,
        person2: bob,
        type: RelationshipType.parent,
        sourceText: 'Mother and son'
      ),
    ], []);
    final shared = (await db.getConnections()).single;
    expect(shared.id, explicit.id);
    expect(shared.originEventId, 'manual-origin');
    expect(shared.person1Id, bob.id);
    expect(shared.relationshipType, 'child');
    expect(shared.description, explicit.description);
    expect(shared.startDate, explicit.startDate);
    expect(shared.endDate, explicit.endDate);
    expect(shared.isInferred, isFalse);
    expect((await db.getConnectionsForEvent(story.id)).single.id, explicit.id);
    await saveTranscriptInformation(db, story, [], []);
    final remaining = (await db.getConnections()).single;
    expect(remaining.sourceEventIds, isEmpty);
    expect(remaining.originEventId, 'manual-origin');
    expect(await db.getConnectionsForEvent(story.id), isEmpty);
  });

  test('multiple stories share symmetric edge and stale origin moves to source',
      () async {
    final otherStory = Event(title: 'Second', dateTime: DateTime(2026, 10, 5));
    await db.saveEvent(otherStory);
    await saveTranscriptInformation(db, story, [
      (
        person1: ada,
        person2: bob,
        type: RelationshipType.friend,
        sourceText: 'Ada and Bob are friends'
      ),
    ], []);
    await saveTranscriptInformation(db, otherStory, [
      (
        person1: bob,
        person2: ada,
        type: RelationshipType.friend,
        sourceText: 'Bob and Ada are friends'
      ),
    ], []);
    final shared = (await db.getConnections()).single;
    expect(shared.sourceEventIds, [story.id, otherStory.id]);
    expect(
        (await db.getConnectionsForEvent(otherStory.id)).single.id, shared.id);
    await saveTranscriptInformation(db, story, [], []);
    final remaining = (await db.getConnections()).single;
    expect(remaining.sourceEventIds, [otherStory.id]);
    expect(remaining.originEventId, otherStory.id);
    expect(remaining.description, shared.description);
    await saveTranscriptInformation(db, otherStory, [], []);
    expect(await db.getConnections(), isEmpty);
    expect((await db.getConnection(shared.id))!.isDeleted, isTrue);
    expect(await db.getConnectionsForEvent(otherStory.id), isEmpty);
  });

  test('edits replace rejected relationship without changing unrelated records',
      () async {
    final unrelated = Connection(
      person1Id: ada.id,
      person2Id: bob.id,
      relationshipType: 'colleague',
      description: 'Manual',
    );
    await db.saveConnection(unrelated);
    await saveTranscriptInformation(db, story, [
      (
        person1: ada,
        person2: bob,
        type: RelationshipType.friend,
        sourceText: 'Friends'
      ),
    ], []);
    await saveTranscriptInformation(db, story, [
      (
        person1: ada,
        person2: bob,
        type: RelationshipType.partner,
        sourceText: 'Partners'
      ),
    ], []);
    expect((await db.getConnections()).map((edge) => edge.relationshipType),
        unorderedEquals(['colleague', 'partner']));
    expect(
        (await db.getConnection(unrelated.id))!.toJson(), unrelated.toJson());
  });

  test('facts preserve notes, attributes, companies and other story sources',
      () async {
    ada = ada.copyWith(
        company: 'Existing company',
        notes: 'Manual notes',
        customAttributes: {'car': 'old'},
        storyFacts: {'other': 'Older story'});
    await db.savePerson(ada);
    final facts = [
      (
        person: ada,
        value: 'Suggested company',
        sourceText: 'Ada works at New Co.',
        isCompany: true
      ),
      (
        person: bob,
        value: 'Garage',
        sourceText: 'Bob works at Garage.',
        isCompany: true
      ),
      (
        person: bob,
        value: 'new car',
        sourceText: 'Bob bought a new car.',
        isCompany: false
      ),
      (
        person: bob,
        value: 'new car',
        sourceText: 'Bob bought a new car.',
        isCompany: false
      ),
    ];
    await saveTranscriptInformation(db, story, [], facts);
    final savedAda = (await db.getPerson(ada.id))!;
    final savedBob = (await db.getPerson(bob.id))!;
    expect(savedAda.company, 'Existing company');
    expect(savedAda.notes, 'Manual notes');
    expect(savedAda.customAttributes, {'car': 'old'});
    expect(savedAda.storyFacts,
        {'other': 'Older story', story.id: 'Ada works at New Co.'});
    expect(savedBob.company, 'Garage');
    expect(savedBob.storyFacts[story.id],
        'Bob works at Garage.\nBob bought a new car.');
    final pending = (await db.getPendingChanges()).length;
    await saveTranscriptInformation(db, story, [], facts);
    expect((await db.getPendingChanges()).length, pending);
    await saveTranscriptInformation(db, story, [], [
      (
        person: bob,
        value: 'car sold',
        sourceText: 'Bob sold the car.',
        isCompany: false
      ),
    ]);
    expect((await db.getPerson(ada.id))!.storyFacts, {'other': 'Older story'});
    expect((await db.getPerson(bob.id))!.storyFacts[story.id],
        'Bob sold the car.');
    expect((await db.getPerson(bob.id))!.company, 'Garage');
  });

  test('empty unrelated extraction writes nothing', () async {
    final pending = (await db.getPendingChanges()).length;
    await saveTranscriptInformation(db, story, [], []);
    expect((await db.getPendingChanges()).length, pending);
  });

  test('unsaved story cannot persist extracted information', () async {
    final pending = (await db.getPendingChanges()).length;
    final unsaved = Event(title: 'Unsaved', dateTime: DateTime.now());
    await expectLater(
        saveTranscriptInformation(db, unsaved, [
          (
            person1: ada,
            person2: bob,
            type: RelationshipType.friend,
            sourceText: 'Friends'
          ),
        ], []),
        throwsStateError);
    expect((await db.getPendingChanges()).length, pending);
  });
}
