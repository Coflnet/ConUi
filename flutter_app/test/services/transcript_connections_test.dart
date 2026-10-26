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

  test('explicit residence facts preserve the address and named person', () {
    for (final text in [
      'John wohnt in Dorfstraße 17',
      'John wohnt in der Dorfstraße 17',
      'John lives at 17 High Street',
      'John lives in Berlin',
    ]) {
      final result = extractTranscriptConnections('$text.', []);
      expect(result.connections, isEmpty);
      expect(result.facts.single.personName, 'John');
      expect(result.facts.single.value, text);
      expect(result.facts.single.sourceText, text);
      expect(result.facts.single.isCompany, isFalse);
    }
  });

  test('relative residence facts keep their named antecedent', () {
    for (final (text, head, evidence) in [
      (
        'Alex is the brother of John, who lives at 17 High Street.',
        'John',
        'who lives at 17 High Street'
      ),
      (
        'Alex ist der Bruder von John der in der Dorfstraße 17 wohnt.',
        'John',
        'der in der Dorfstraße 17 wohnt'
      ),
      (
        'Alex is John’s brother, who lives in Berlin.',
        'Alex',
        'who lives in Berlin'
      ),
    ]) {
      final result = extractTranscriptConnections(text, []);
      expect(result.facts.single.personName, head, reason: text);
      expect(result.facts.single.sourceText, evidence);
    }
    final result = extractTranscriptConnections(
        'John works at Zeta and lives at 17 High Street.', []);
    expect(result.facts.map((fact) => fact.personName), ['John', 'John']);
    expect(result.facts.last.sourceText, 'lives at 17 High Street');
  });

  test('residence facts reject negation, questions, uncertainty and pronouns',
      () {
    for (final text in [
      'John wohnt nicht in Dorfstraße 17.',
      'John wohnt in Dorfstraße 17?',
      'Vielleicht wohnt John in Dorfstraße 17.',
      'John lives at 17 High Street, allegedly.',
      'John does not live in Berlin.',
      'John might live in Berlin.',
      'He lives at 17 High Street.',
      'Sie wohnt in Dorfstraße 17.',
      'John lives in.',
    ]) {
      expect(extractTranscriptConnections(text, []).facts, isEmpty,
          reason: text);
    }
  });

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

  test('possessive relative head is the role holder, direct head is the owner',
      () {
    for (final (text, head) in [
      (
        'Alex is Ben’s brother, who works at Zeta and is a colleague of Dana.',
        'Alex'
      ),
      (
        'Alex is the brother of Ben, who works at Zeta and is a colleague of Dana.',
        'Ben'
      ),
      (
        'Alex ist Bens Bruder, der bei Zeta arbeitet und ein Kollege von Dana ist.',
        'Alex'
      ),
      (
        'Alex ist der Bruder von Ben, der bei Zeta arbeitet und ein Kollege von Dana ist.',
        'Ben'
      ),
    ]) {
      final result = extractTranscriptConnections(text, []);
      expect(
          triples(result),
          [
            ('Alex', RelationshipType.sibling, 'Ben'),
            (head, RelationshipType.colleague, 'Dana'),
          ],
          reason: text);
      expect(result.facts.single.personName, head, reason: text);
      expect(result.facts.single.value, 'Zeta');
      expect(result.facts.single.isCompany, isTrue);
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

  test('reverse possessives preserve role direction and named relative head',
      () {
    for (final text in [
      'Ben’s father is Alex, who works at Zeta.',
      "Ben's father is Alex, who works at Zeta.",
      'Bens Vater ist Alex, der bei Zeta arbeitet.',
      'Hans’ Vater ist Alex, der bei Zeta arbeitet.',
    ]) {
      final result = extractTranscriptConnections(text, []);
      expect(
          triples(result),
          [
            (
              'Alex',
              RelationshipType.parent,
              text.startsWith('Hans') ? 'Hans' : 'Ben'
            ),
          ],
          reason: text);
      expect(result.facts.single.personName, 'Alex', reason: text);
      expect(result.connections.single.sourceText, text.split(',').first);
    }
    expect(
        triples(extractTranscriptConnections(
            "Alex is Hans' father. Hans ist Alex’ Sohn.", [])),
        [
          ('Alex', RelationshipType.parent, 'Hans'),
        ]);
  });

  test('named appositives preserve evidence and refer back to the role holder',
      () {
    for (final description in [
      'Ben’s sister',
      'the sister of Ben',
      'Bens Schwester',
      'die Schwester von Ben',
    ]) {
      final result = extractTranscriptConnections(
          'Alex, $description, who works at Zeta and is a colleague of Dana.',
          []);
      expect(
          triples(result),
          [
            ('Alex', RelationshipType.sibling, 'Ben'),
            ('Alex', RelationshipType.colleague, 'Dana'),
          ],
          reason: description);
      expect(result.facts.single.personName, 'Alex');
      expect(result.connections.first.sourceText, 'Alex, $description');
    }
    final german = extractTranscriptConnections(
        'Alex, die Mutter von Ben, arbeitet bei Zeta.', []);
    expect(triples(german), [('Alex', RelationshipType.parent, 'Ben')]);
    expect(german.facts.single.personName, 'Alex');
    expect(
        extractTranscriptConnections('Alex, Ben’s sister.', [])
            .connections
            .single
            .sourceText,
        'Alex, Ben’s sister');
  });

  test('explicit paired statements support symmetric relationships only', () {
    final cases = <String, RelationshipType>{
      'siblings': RelationshipType.sibling,
      'brothers': RelationshipType.sibling,
      'sisters': RelationshipType.sibling,
      'friends': RelationshipType.friend,
      'colleagues': RelationshipType.colleague,
      'partners': RelationshipType.partner,
      'spouses': RelationshipType.spouse,
      'married': RelationshipType.spouse,
      'Geschwister': RelationshipType.sibling,
      'Brüder': RelationshipType.sibling,
      'Schwestern': RelationshipType.sibling,
      'Freunde': RelationshipType.friend,
      'Freundinnen': RelationshipType.friend,
      'Kollegen': RelationshipType.colleague,
      'Kolleginnen': RelationshipType.colleague,
      'Partner': RelationshipType.partner,
      'Partnerinnen': RelationshipType.partner,
      'verheiratet': RelationshipType.spouse,
      'neighbors': RelationshipType.neighbour,
      'neighbours': RelationshipType.neighbour,
      'Nachbarn': RelationshipType.neighbour,
      'Nachbarinnen': RelationshipType.neighbour,
      'half-siblings': RelationshipType.halfSibling,
      'Halbgeschwister': RelationshipType.halfSibling,
    };
    for (final entry in cases.entries) {
      for (final pair in ['Alex and Ben are', 'Alex und Ben sind']) {
        final statement = '$pair ${entry.key}';
        final result = extractTranscriptConnections('$statement.', []);
        expect(triples(result), [('Alex', entry.value, 'Ben')],
            reason: statement);
        expect(result.connections.single.sourceText, statement);
      }
    }
  });

  test('extended explicit roles preserve directions and deduplicate inverses',
      () {
    for (final (parent, child, type) in [
      ('grandparent', 'grandchild', RelationshipType.grandparent),
      ('grandfather', 'grandson', RelationshipType.grandparent),
      ('grandmother', 'granddaughter', RelationshipType.grandparent),
      ('Großvater', 'Enkel', RelationshipType.grandparent),
      ('Großmutter', 'Enkelin', RelationshipType.grandparent),
      ('Opa', 'Enkel', RelationshipType.grandparent),
      ('Oma', 'Enkelin', RelationshipType.grandparent),
      ('stepparent', 'stepchild', RelationshipType.stepParent),
      ('step-parent', 'Stiefkind', RelationshipType.stepParent),
      ('stepfather', 'stepson', RelationshipType.stepParent),
      ('stepmother', 'stepdaughter', RelationshipType.stepParent),
      ('Stiefvater', 'Stiefsohn', RelationshipType.stepParent),
      ('Stiefmutter', 'Stieftochter', RelationshipType.stepParent),
    ]) {
      final result = extractTranscriptConnections(
          'Alex is the $parent of Ben. Ben is Alex’s $child.', []);
      expect(triples(result), [('Alex', type, 'Ben')], reason: parent);
    }
    for (final (role, type) in [
      ('half-sibling', RelationshipType.halfSibling),
      ('half-brother', RelationshipType.halfSibling),
      ('half-sister', RelationshipType.halfSibling),
      ('Halbbruder', RelationshipType.halfSibling),
      ('Halbschwester', RelationshipType.halfSibling),
      ('neighbor', RelationshipType.neighbour),
      ('neighbour', RelationshipType.neighbour),
      ('Nachbar', RelationshipType.neighbour),
      ('Nachbarin', RelationshipType.neighbour),
    ]) {
      final result = extractTranscriptConnections(
          'Alex is the $role of Ben. Ben is the $role of Alex.', []);
      expect(triples(result), [('Alex', type, 'Ben')], reason: role);
    }
  });

  test('explicit named roles identify people without inferring narrator links',
      () {
    for (final text in [
      'Meine Schwester Anna ist Pauls Mutter.',
      'My sister Anna is Paul’s mother.',
      'Anna ist der Vater von meinem Bruder Paul.',
    ]) {
      final result = extractTranscriptConnections(text, [Person(name: 'Anna')]);
      expect(result.connections.single.person1Name, 'Anna');
      expect(result.connections.single.person2Name, 'Paul');
      expect(result.connections, hasLength(1));
      expect(result.connections.single.sourceText,
          text.substring(0, text.length - 1));
    }
  });

  test('married wording deduplicates paired and reversed spouse claims', () {
    final result = extractTranscriptConnections(
        'Alex is married to Ben. Ben ist mit Alex verheiratet. '
        'Alex und Ben sind verheiratet.',
        []);
    expect(triples(result), [('Alex', RelationshipType.spouse, 'Ben')]);
    expect(result.connections.single.sourceText, 'Alex is married to Ben');
  });

  test('marriage relatives refer to the named spouse', () {
    for (final text in [
      'Alex is married to Ben, who works at Zeta and is a friend of Dana.',
      'Alex ist mit Ben verheiratet, der bei Zeta arbeitet und ein Freund von Dana ist.',
    ]) {
      final result = extractTranscriptConnections(text, []);
      expect(
          triples(result),
          [
            ('Alex', RelationshipType.spouse, 'Ben'),
            ('Ben', RelationshipType.friend, 'Dana'),
          ],
          reason: text);
      expect(result.facts.single.personName, 'Ben', reason: text);
    }
  });

  test('new forms reject pronouns, uncertainty, invalid pairs and role nouns',
      () {
    for (final text in [
      'He and Ben are friends.',
      'Alex und sie sind Geschwister.',
      'Alex and Ben are parents.',
      'My sister is Paul’s mother.',
      'Meine Schwester ist Pauls Mutter.',
      'Alex is the uncle of Ben.',
      'Alex ist die Tante von Ben.',
      'Alex and Ben and Dana are colleagues.',
      'Alex and Ben And Dana are colleagues.',
      'Alex UND Ben UND Dana sind Kollegen.',
      'Alex and Alex are friends.',
      'Alex and Ben are not friends.',
      'Alex und Ben sind keine Freunde.',
      'Alex and Ben are friends?',
      'If Alex and Ben are married, Alex works at Zeta.',
      'Someone said Alex and Ben are married.',
      'Alex and Ben were friends.',
      'Alex and Ben are former colleagues.',
      'Alex, supposedly Ben’s sister, works at Zeta.',
      'Alex, Ben’s sister, works at Zeta, supposedly.',
      'Alex is the brother of Ben, allegedly.',
      'Alex ist der Bruder von Ben, anscheinend.',
      'Alex, nicht Bens Schwester, arbeitet bei Zeta.',
      'His brother is Alex.',
      'Alex is His brother.',
      'Alex, His brother, works at Zeta.',
      'Sein Vater ist Alex.',
      'Ben’s father might be Alex.',
      'The car, Ben’s brother, works at Zeta.',
      'Alex is married to her.',
      'Alex is married to Her.',
      'Alex and Him are friends.',
      'Alex und Ihr sind Geschwister.',
      'Alex ist mit ihr verheiratet.',
      '"Alex and Ben are married."',
    ]) {
      final result = extractTranscriptConnections(text, []);
      expect(result.connections, isEmpty, reason: text);
      expect(result.facts, isEmpty, reason: text);
    }
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
