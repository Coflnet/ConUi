import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/models/person.dart';
import 'package:relationship_manager/relationships/relationship_type.dart';
import 'package:relationship_manager/services/transcript_connections.dart';

void main() {
  List<(String, RelationshipType, String)> triples(
          TranscriptConnections result) =>
      result.connections
          .map((c) => (c.person1Name, c.type, c.person2Name))
          .toList();

  test('English explicit slots introduce people and keep relative subject', () {
    final result = extractTranscriptConnections(
        'Alex got a new car. Alex is the brother of Ben, who works at Zeta '
        'and is a colleague of Dana.',
        []);
    expect(triples(result), [
      ('Alex', RelationshipType.sibling, 'Ben'),
      ('Ben', RelationshipType.colleague, 'Dana'),
    ]);
    expect(result.facts.map((f) => (f.personName, f.value, f.isCompany)), [
      ('Alex', 'Alex got a new car', false),
      ('Ben', 'Zeta', true),
    ]);
    expect(result.connections.first.sourceText, 'Alex is the brother of Ben');
    expect(result.facts.last.sourceText, 'who works at Zeta');
  });

  test('German relative and coordinated predicate retain Ben, not Alex', () {
    final result = extractTranscriptConnections(
        'Alex hat ein neues Auto. Alex ist der Bruder von Ben, der bei Zeta '
        'arbeitet und ein Kollege von Dana ist.',
        []);
    expect(triples(result), [
      ('Alex', RelationshipType.sibling, 'Ben'),
      ('Ben', RelationshipType.colleague, 'Dana'),
    ]);
    expect(result.facts.map((f) => (f.personName, f.value, f.isCompany)), [
      ('Alex', 'Alex hat ein neues Auto', false),
      ('Ben', 'Zeta', true),
    ]);
  });

  test('unpunctuated spoken relative clauses retain the named antecedent', () {
    for (final text in [
      'Alex got a new car. Alex is the brother of Ben who works at Zeta '
          'and is a colleague of Dana.',
      'Alex hat ein neues Auto. Alex ist der Bruder von Ben der bei Zeta '
          'arbeitet und ein Kollege von Dana ist.',
    ]) {
      final result = extractTranscriptConnections(text, []);
      expect(
          triples(result),
          [
            ('Alex', RelationshipType.sibling, 'Ben'),
            ('Ben', RelationshipType.colleague, 'Dana'),
          ],
          reason: text);
      expect(result.facts.singleWhere((f) => f.isCompany).personName, 'Ben');
      expect(result.facts.singleWhere((f) => f.isCompany).value, 'Zeta');
      expect(result.facts.singleWhere((f) => !f.isCompany).personName, 'Alex');
    }
  });

  test('parent and child direction and symmetric inverse deduplication', () {
    final result = extractTranscriptConnections(
        'Alex is the father of Ben. Ben is the son of Alex. '
        'Dana ist die Mutter von Ella. Ella ist die Tochter von Dana. '
        'Alex is a friend of Dana. Dana is a friend of Alex. '
        'Alex is the brother of Alex.',
        []);
    expect(triples(result), [
      ('Alex', RelationshipType.parent, 'Ben'),
      ('Dana', RelationshipType.parent, 'Ella'),
      ('Alex', RelationshipType.friend, 'Dana'),
    ]);
  });

  test('supported vocabulary maps without introducing company endpoints', () {
    final cases = <String, RelationshipType>{
      'sister': RelationshipType.sibling,
      'mother': RelationshipType.parent,
      'daughter': RelationshipType.child,
      'collegue': RelationshipType.colleague,
      'partner': RelationshipType.partner,
      'wife': RelationshipType.spouse,
      'Schwester': RelationshipType.sibling,
      'Vater': RelationshipType.parent,
      'Sohn': RelationshipType.child,
      'Kollegin': RelationshipType.colleague,
      'Freundin': RelationshipType.friend,
      'Partnerin': RelationshipType.partner,
      'Ehemann': RelationshipType.spouse,
    };
    for (final entry in cases.entries) {
      final result =
          extractTranscriptConnections('Alex is ${entry.key} of Ben.', []);
      expect(result.connections.single.type, entry.value);
    }
    final result = extractTranscriptConnections('Ben works at Zeta.', []);
    expect(result.connections, isEmpty);
    expect(result.facts.single.personName, 'Ben');
    expect(result.facts.single.value, 'Zeta');
  });

  test('possessive English and German preserve who has the role', () {
    expect(
        triples(extractTranscriptConnections(
            'Alex is Ben’s brother. Dana ist Ellas Mutter.', [])),
        [
          ('Alex', RelationshipType.sibling, 'Ben'),
          ('Dana', RelationshipType.parent, 'Ella'),
        ]);
  });

  test(
      'explicit conjunction subject replaces scope; no general pronoun guesses',
      () {
    final result = extractTranscriptConnections(
        'Alex is the brother of Ben and is a friend of Dana. '
        'Xavier is the father of Yvonne and Zoe is a colleague of Walter. '
        'He is the brother of Ben. Sie arbeitet bei Zeta. '
        'Alex met Ben and is a friend of Dana.',
        []);
    expect(triples(result), [
      ('Alex', RelationshipType.sibling, 'Ben'),
      ('Alex', RelationshipType.friend, 'Dana'),
      ('Xavier', RelationshipType.parent, 'Yvonne'),
      ('Zoe', RelationshipType.colleague, 'Walter'),
    ]);
    expect(result.facts, isEmpty);
  });

  test('relative predicate can itself carry a relationship', () {
    expect(
        triples(extractTranscriptConnections(
            'Alex is the brother of Ben, who is a friend of Dana. '
            'Ella ist die Schwester von Fran, die eine Kollegin von Greta ist.',
            [])),
        [
          ('Alex', RelationshipType.sibling, 'Ben'),
          ('Ben', RelationshipType.friend, 'Dana'),
          ('Ella', RelationshipType.sibling, 'Fran'),
          ('Fran', RelationshipType.colleague, 'Greta'),
        ]);
  });

  test('negation, questions, modal and reported uncertainty produce no facts',
      () {
    for (final text in [
      'Alex is not the brother of Ben.',
      'Alex ist nicht der Bruder von Ben.',
      'Alex is the brother of Ben?',
      'Is Alex the brother of Ben?',
      'Alex might be the brother of Ben.',
      'Maybe Alex is the brother of Ben.',
      'If Alex is the brother of Ben, Ben works at Zeta.',
      'Someone said Alex is the brother of Ben.',
      'Alex ist wohl der Bruder von Ben.',
      'Ben works at Zeta, perhaps.',
      'Ben hat kein neues Auto.',
    ]) {
      final result = extractTranscriptConnections(text, []);
      expect(result.connections, isEmpty, reason: text);
      expect(result.facts, isEmpty, reason: text);
    }
  });

  test('Unicode names and aliases preserve spelling and deduplicate identity',
      () {
    final people = [
      Person(id: 'a', name: "Élodie O'Connor", aliases: ['Änni']),
      Person(id: 'b', name: 'Ben Müller'),
    ];
    final result = extractTranscriptConnections(
        'Änni is the sister of Ben. Ben Müller is the brother of Élodie O’Connor. '
        'Änni is a friend of Élodie O’Connor.',
        people);
    expect(triples(result), [('Änni', RelationshipType.sibling, 'Ben')]);
  });

  test('colliding aliases stay separate until caller resolves them', () {
    final result = extractTranscriptConnections('Alex is a friend of Sam.', [
      Person(id: 'a', name: 'Alex One'),
      Person(id: 'b', name: 'Alex Two'),
      Person(id: 'c', name: 'Sam'),
    ]);
    expect(result.connections.single.person1Name, 'Alex');
  });

  test('known first name cannot consume an unfamiliar full name', () {
    final result = extractTranscriptConnections(
        'Anna Müller is a friend of Anna Schmidt.', [
      Person(id: 'anna', name: 'Anna Schmidt'),
    ]);
    expect(result.connections.single.person1Name, 'Anna Müller');
    expect(result.connections.single.person2Name, 'Anna Schmidt');
  });

  test('company repeats deduplicate and standalone car facts retain clause',
      () {
    final result = extractTranscriptConnections(
        'Ben works at Zeta. Ben arbeitet bei Zeta. Alex bought a new car.', []);
    expect(result.facts, hasLength(2));
    expect(result.facts.last.value, 'Alex bought a new car');
    expect(result.facts.last.sourceText, 'Alex bought a new car');
  });

  test('German common nouns never become unfamiliar people', () {
    final result = extractTranscriptConnections(
        'Das Auto ist der Bruder von Ben. Garten works at Zeta. '
        'Weihnachten hat ein neues Auto. Firma ist ein Partner von Ben.',
        []);
    expect(result.connections, isEmpty);
    expect(result.facts, isEmpty);
  });

  test('tail edits and reruns have no hidden state', () {
    const head = 'Alex is the brother of Ben';
    expect(extractTranscriptConnections(head, []).connections, hasLength(1));
    final tail =
        extractTranscriptConnections('$head and is a friend of Dana.', []);
    expect(tail.connections, hasLength(2));
    expect(
        extractTranscriptConnections('Alex is a friend of Dana.', [])
            .connections
            .single
            .type,
        RelationshipType.friend);
    expect(extractTranscriptConnections(head, []).facts, isEmpty);
  });
}
