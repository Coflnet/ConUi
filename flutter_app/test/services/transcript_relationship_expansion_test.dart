import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/models/person.dart';
import 'package:relationship_manager/relationships/relationship_type.dart';
import 'package:relationship_manager/services/transcript_connections.dart';
import 'package:relationship_manager/services/transcript_relationship_vocabulary.dart';

void main() {
  List<(String, RelationshipType, String)> triples(String text,
          [List<Person> people = const []]) =>
      extractTranscriptConnections(text, people)
          .connections
          .map((c) => (c.person1Name, c.type, c.person2Name))
          .toList();

  test('every explicit role word preserves its type and literal evidence', () {
    for (final entry in transcriptRelationshipWords.entries) {
      final sentence = entry.key == 'chef'
          ? 'Anna ist der Chef von Ben'
          : 'Anna is the ${entry.key} of Ben';
      final result = extractTranscriptConnections('$sentence.', []);
      expect(result.connections, hasLength(1), reason: sentence);
      expect(result.connections.single.type, entry.value, reason: sentence);
      expect(result.connections.single.sourceText, sentence);
    }
  });

  test('natural predicates keep explicit endpoints and direction', () {
    for (final (text, type) in [
      ('Anna is friends with Ben', RelationshipType.friend),
      ('Anna ist mit Ben befreundet', RelationshipType.friend),
      ('Anna and Ben work together', RelationshipType.colleague),
      ('Anna und Ben arbeiten zusammen', RelationshipType.colleague),
      ('Anna works with Ben', RelationshipType.colleague),
      ('Anna and Ben know each other', RelationshipType.acquaintance),
      ('Anna und Ben kennen sich', RelationshipType.acquaintance),
      ('Anna kennt Ben', RelationshipType.acquaintance),
      ('Anna is in a relationship with Ben', RelationshipType.partner),
      ('Anna ist mit Ben zusammen', RelationshipType.partner),
      ('Anna is divorced from Ben', RelationshipType.exPartner),
      ('Anna ist von Ben geschieden', RelationshipType.exPartner),
      ('Anna adopted Ben', RelationshipType.adoptiveParent),
      ('Anna hat Ben adoptiert', RelationshipType.adoptiveParent),
      ('Anna mentors Ben', RelationshipType.mentor),
      ('Anna betreut Ben als Mentorin', RelationshipType.mentor),
      ('Anna teaches Ben', RelationshipType.teacher),
      ('Anna unterrichtet Ben', RelationshipType.teacher),
      ('Anna reports to Ben', RelationshipType.directReport),
      ('Anna berichtet an Ben', RelationshipType.directReport),
    ]) {
      expect(triples('$text.'), [('Anna', type, 'Ben')], reason: text);
    }
  });

  test('having named roles reverses owner and supports named objects', () {
    for (final text in [
      'Anna has a daughter Ben.',
      'Anna hat eine Tochter namens Ben.'
    ]) {
      expect(triples(text), [('Ben', RelationshipType.child, 'Anna')]);
    }
    expect(triples('Anna has a mentor named Ben.'),
        [('Ben', RelationshipType.mentor, 'Anna')]);
    expect(triples('Anna hat einen Sohn namens Ben und Clara.'), [
      ('Ben', RelationshipType.child, 'Anna'),
      ('Clara', RelationshipType.child, 'Anna'),
    ]);
  });

  test('bounded lists use a common endpoint or explicit collective role', () {
    expect(triples('Anna is the parent of Ben, Clara and David.'), [
      ('Anna', RelationshipType.parent, 'Ben'),
      ('Anna', RelationshipType.parent, 'Clara'),
      ('Anna', RelationshipType.parent, 'David'),
    ]);
    for (final text in [
      'Anna and Ben are the parents of Clara.',
      'Anna und Ben sind Eltern von Clara.'
    ]) {
      expect(triples(text), [
        ('Anna', RelationshipType.parent, 'Clara'),
        ('Ben', RelationshipType.parent, 'Clara'),
      ]);
    }
    expect(triples('Anna, Ben and Clara are friends.'), [
      ('Anna', RelationshipType.friend, 'Ben'),
      ('Anna', RelationshipType.friend, 'Clara'),
      ('Ben', RelationshipType.friend, 'Clara'),
    ]);
    expect(triples('Anna, Ben und Clara sind Geschäftspartner.'), [
      ('Anna', RelationshipType.businessPartner, 'Ben'),
      ('Anna', RelationshipType.businessPartner, 'Clara'),
      ('Ben', RelationshipType.businessPartner, 'Clara'),
    ]);
    for (final text in [
      'Anna and Ben are parents of Clara and David.',
      'Anna is the parent of Ben or Clara.',
      'Anna is the parent of Ben, Clara.',
      'Anna and Ben and Clara are partners.'
    ]) {
      expect(triples(text), isEmpty, reason: text);
    }
  });

  test('new relationships deduplicate inverse wording and aliases', () {
    expect(
        triples('Anni is the teacher of Ben. Ben is Anna’s student.', [
          Person(id: 'a', name: 'Anna', aliases: ['Anni']),
          Person(id: 'b', name: 'Ben'),
        ]),
        [('Anni', RelationshipType.teacher, 'Ben')]);
    expect(triples('Anna is the aunt of Ben. Ben is Anna’s nephew.'),
        [('Anna', RelationshipType.auntOrUncle, 'Ben')]);
  });

  test('uncertainty pets organizations and cooccurrence stay conservative', () {
    for (final text in [
      'Anna has no daughter named Ben.',
      'Anna has a daughter named Ben?',
      'Anna might have a daughter named Ben.',
      'Anna hat vielleicht eine Tochter namens Ben.',
      'Someone says Anna adopted Ben.',
      'If Anna mentors Ben, Clara helps.',
      'Anna is friends with her.',
      'Anna hat einen Hund namens Ben.',
      'Mein Hund Milo ist der Freund von Anna.',
      'Acme GmbH is a partner of Beta Ltd.',
      'The company Atlas is the manager of Ben.',
      'Die Firma Atlas ist ein Partner von Ben.',
      'Firma Atlas ist ein Partner von Ben.',
      'Anna is a friend of Mine.',
      'Mentor is the friend of Ben.',
      'Anna and Ben live together in Berlin.',
      'Anna and Ben play tennis.',
      'Anna met Ben. She is the mentor of Clara.',
      'Anna will marry Ben.',
      'Anna was married to Ben.',
      'Anna ist nicht mit Ben befreundet.',
      'Anna is Ben’s chef.',
      'Anna ist der Schulkamerad von Ben.',
      'Anna ist der Untergebene von Ben.',
    ]) {
      expect(triples(text), isEmpty, reason: text);
    }
  });

  test('expanded predicates preserve relative and coordinated clause scope',
      () {
    final result = extractTranscriptConnections(
        'Anna adopted Ben, who works at Atlas and mentors Clara.', []);
    expect(
        result.connections.map((c) => (c.person1Name, c.type, c.person2Name)), [
      ('Anna', RelationshipType.adoptiveParent, 'Ben'),
      ('Ben', RelationshipType.mentor, 'Clara'),
    ]);
    expect(result.facts.single.personName, 'Ben');
    expect(result.facts.single.value, 'Atlas');
    final workers =
        extractTranscriptConnections('Anna und Ben arbeiten bei Atlas.', []);
    expect(workers.facts.map((f) => (f.personName, f.value)),
        [('Anna', 'Atlas'), ('Ben', 'Atlas')]);
    expect(workers.connections, isEmpty);
  });

  test('titles retain human endpoints and literal source text', () {
    final result = extractTranscriptConnections(
        'Dr. Anna is the mentor of Prof. Ben.', []);
    expect(result.connections.single.person1Name, 'Anna');
    expect(result.connections.single.person2Name, 'Ben');
    expect(result.connections.single.sourceText,
        'Dr. Anna is the mentor of Prof. Ben');
  });
}
