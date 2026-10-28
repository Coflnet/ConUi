import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/models/person.dart';
import 'package:relationship_manager/services/person_mentions.dart';

void main() {
  test('new human roles and their genitives reuse known people', () {
    final anna = Person(id: 'anna', name: 'Anna Müller');
    for (final role in [
      'Mentorin',
      'Mitbewohnerin',
      'Lehrerin',
      'Chefin',
      'Geschäftspartnerin',
      'Schwägerin',
      'Patentante',
      'Arbeitgeberin'
    ]) {
      expect(
          extractPersonMentions('Annas $role heißt Clara.', [anna]).any(
              (mention) =>
                  mention.matches.any((person) => person.id == anna.id)),
          isTrue,
          reason: role);
    }
    for (final text in [
      'My mentor Anna arrived.',
      'Meine Mitbewohnerin Anna kam.',
      'My teacher is Anna.',
      'Meine Lehrerin ist Anna.'
    ]) {
      expect(
          extractPersonMentions(text, [anna]).single.matches.single.id, 'anna',
          reason: text);
    }
  });

  test('explicit human introductions recognize named lists and academic titles',
      () {
    for (final text in [
      'Our colleagues Anna, Ben and Clara arrived.',
      'Meine Mitbewohner Anna, Ben und Clara kamen.',
      'My friends are Anna, Ben and Clara.'
    ]) {
      expect(extractPersonMentions(text, []).map((mention) => mention.name),
          ['Anna', 'Ben', 'Clara'],
          reason: text);
    }
    expect(
        extractPersonMentions('Meine Mentorin Dr. Clara Müller kam.', [])
            .single
            .name,
        'Clara Müller');
    expect(
        extractPersonMentions('My colleague Anna, Berlin was sunny.', [])
            .map((mention) => mention.name),
        ['Anna']);
    expect(
        extractPersonMentions("My mentor Ben's colleague arrived.", [])
            .any((mention) => mention.name == "Ben's"),
        isFalse);
  });

  test('named pets and companies do not reuse a familiar human identity', () {
    final people = [
      Person(name: 'Milo'),
      Person(name: 'Rex'),
      Person(name: 'Atlas')
    ];
    for (final text in [
      'Mein Hund Milo kam.',
      'My dog Milo arrived.',
      'Meine Hunde Milo und Rex kamen.',
      'My dogs named Milo and Rex arrived.',
      'My business partner Atlas GmbH expanded.'
    ]) {
      expect(extractPersonMentions(text, people), isEmpty, reason: text);
    }
    expect(
        extractPersonMentions(
                'Atlas GmbH expanded. My colleague Atlas arrived.', people)
            .single
            .matches
            .single
            .name,
        'Atlas');
  });

  test('normalizes whitespace, case and apostrophes', () {
    expect(normalizedPersonName('  Élodie   O’Connor '), "élodie o'connor");
  });

  test('known Unicode names and aliases match whole words and deduplicate IDs',
      () {
    final person = Person(id: 'a', name: 'Anna Müller', aliases: ['Änni']);
    final mentions = extractPersonMentions(
        'Ananas Annabelle Änni und ANNA  MÜLLER besuchten Berlin.', [person]);
    expect(mentions, hasLength(1));
    expect(mentions.single.matches.single.id, 'a');
    expect(extractPersonMentions('Annabelle Ananas Ännina', [person]), isEmpty);
  });

  test('longest overlapping name wins over first names and partial aliases',
      () {
    final anna = Person(id: 'a', name: 'Anna Müller');
    final other = Person(id: 'b', name: 'Maria Weber', aliases: ['Anna']);
    final mentions =
        extractPersonMentions('Anna Müller und Anna Müller', [anna, other]);
    expect(mentions, hasLength(1));
    expect(mentions.single.matches.map((p) => p.id), ['a']);
  });

  test('shared first names and aliases remain ambiguous', () {
    final people = [
      Person(id: 'a', name: 'Paul Müller', aliases: ['Paule']),
      Person(id: 'b', name: 'Paul Schmidt', aliases: ['Paule']),
    ];
    final mentions = extractPersonMentions('Paul und Paule', people);
    expect(mentions, hasLength(1));
    expect(mentions.single.matches.map((p) => p.id), ['a', 'b']);
  });

  test('deleted people cannot match', () {
    expect(
        extractPersonMentions('Anna', [
          Person(name: 'Anna', isDeleted: true),
        ]),
        isEmpty);
  });

  test('German human cues suggest names without guessing capitalized nouns',
      () {
    final mentions = extractPersonMentions(
        'Meine Schwester Anna Müller traf Onkel Paul. '
        'Im Garten in Berlin war Weihnachten schön. Anna Müller ging heim.',
        []);
    expect(mentions.map((m) => m.name), ['Anna Müller', 'Paul']);
    expect(mentions.every((m) => m.matches.isEmpty), isTrue);
    expect(extractPersonMentions('Garten Berlin Weihnachten Stadt Museum', []),
        isEmpty);
  });

  test('relationship prepositions do not become name particles', () {
    expect(
        extractPersonMentions('Alex ist der Bruder von Ben.', [])
            .map((m) => m.name),
        isEmpty);
    expect(
        extractPersonMentions('Herr von Ben kam.', []).single.name, 'von Ben');
  });

  test('English cues support particles, hyphens and apostrophes', () {
    final mentions = extractPersonMentions(
        "My sister Jane Smith met Mr. van Helsing. "
        "Someone named Élodie O’Connor greeted aunt Anne-Marie de Vries.",
        []);
    expect(mentions.map((m) => m.name), [
      'Jane Smith',
      'van Helsing',
      'Élodie O’Connor',
      'Anne-Marie de Vries'
    ]);
  });

  test('German named cues and full names suppress repeated short references',
      () {
    final mentions = extractPersonMentions(
        'Sie heißt Anna. Meine Schwester Anna Müller und Tante Anna Müller kamen.',
        []);
    expect(mentions.map((m) => m.name), ['Anna Müller']);
  });

  test('pet naming cues never propose unfamiliar or known humans', () {
    for (final text in [
      'Jana hat einen Hund namens Milo.',
      'Ihre Katze heißt Milo.',
      'Ihr Kater heisst Milo.',
      'She has a dog named Milo.',
      'Her kitten is called Milo.',
      'Her rabbit named Milo arrived.',
    ]) {
      for (final people in [
        <Person>[],
        [Person(name: 'Milo')]
      ]) {
        expect(extractPersonMentions(text, people), isEmpty, reason: text);
      }
    }
  });

  test('pet names do not suppress independent human mentions or human cues',
      () {
    const pet = 'Jana hat einen Hund namens Milo. ';
    for (final text in [
      '${pet}Herr Milo kam.',
      '${pet}Mein Bruder Milo kam.',
      '${pet}A person named Milo arrived.',
    ]) {
      expect(extractPersonMentions(text, []).single.name, 'Milo');
      final known = Person(id: 'human-milo', name: 'Milo');
      expect(extractPersonMentions(text, [known]).single.matches.single.id,
          known.id);
    }
    expect(
        extractPersonMentions('${pet}Milo kam.', [Person(name: 'Milo')])
            .single
            .name,
        'Milo');
  });

  test('same first name does not merge two unfamiliar full names', () {
    final mentions = extractPersonMentions(
        'Sister Anna Müller met sister Anna Schmidt and aunt Anna.', []);
    expect(
        mentions.map((m) => m.name), ['Anna Müller', 'Anna Schmidt', 'Anna']);
  });

  test('known apostrophe names allow typographic transcript spelling', () {
    final person = Person(name: "Élodie O'Connor");
    expect(
        extractPersonMentions('ÉLODIE O’CONNOR', [person])
            .single
            .matches
            .single
            .id,
        person.id);
  });

  test('hyphenated words do not produce partial first-name matches', () {
    expect(
        extractPersonMentions('Anna-Maria', [Person(name: 'Anna')]), isEmpty);
  });

  test('English possessives recognize known names without matching substrings',
      () {
    final anna = Person(id: 'anna', name: 'Anna Müller');
    for (final text in ["Anna's brother", 'Anna’s story']) {
      expect(extractPersonMentions(text, [anna]).single.matches.single.id,
          anna.id);
    }
    expect(
        extractPersonMentions(
            "Annabel's story Annabelle’s story Anna-Maria", [anna]),
        isEmpty);
  });

  test('German possessives retain known endpoints without plural substrings',
      () {
    final ben = Person(id: 'ben', name: 'Ben Müller');
    final hans = Person(id: 'hans', name: 'Hans');
    for (final text in ['Bens Vater ist Alex.', 'Alex ist Bens Mutter.']) {
      expect(
          extractPersonMentions(text, [ben])
              .singleWhere((mention) => mention.matches.isNotEmpty)
              .matches
              .single
              .id,
          'ben');
    }
    for (final text in ["Hans' Vater ist Alex.", 'Alex ist Hans’ Mutter.']) {
      expect(
          extractPersonMentions(text, [hans])
              .singleWhere((mention) => mention.matches.isNotEmpty)
              .matches
              .single
              .id,
          'hans');
    }
    for (final text in [
      'Bens kamen.',
      'Benson',
      'Bensons Vater',
      'Benstown',
      'Hans’ville',
      'Hansens Vater',
    ]) {
      expect(extractPersonMentions(text, [ben, hans]), isEmpty, reason: text);
    }
  });

  test('academic titles after a human cue are not new person names', () {
    final mentions = extractPersonMentions(
        'Herr Dr. Müller kam. Frau Prof. Schmidt blieb.', []);
    expect(mentions.map((m) => m.name), ['Müller', 'Schmidt']);
    expect(extractPersonMentions('Herr Dr.', []), isEmpty);
  });

  test('a cued surname reuses a unique known person and retains ambiguity', () {
    final anna = Person(id: 'anna', name: 'Anna Müller');
    final paul = Person(id: 'paul', name: 'Paul Müller');
    final unique = extractPersonMentions('Herr Dr. Müller kam.', [anna]);
    expect(unique.single.name, 'Müller');
    expect(unique.single.matches.single.id, anna.id);
    final ambiguous = extractPersonMentions('Herr Müller kam.', [anna, paul]);
    expect(ambiguous.single.matches.map((p) => p.id), ['anna', 'paul']);
    expect(extractPersonMentions('Müller kam.', [anna]), isEmpty);
  });

  test('exact aliases and first names precede cued surname fallback', () {
    final anna = Person(id: 'anna', name: 'Anna Müller');
    final exact = Person(id: 'exact', name: 'Müller Weber');
    final alias = Person(id: 'alias', name: 'Mary Smith', aliases: ['Müller']);
    expect(
        extractPersonMentions('Herr Müller', [anna, exact])
            .single
            .matches
            .single
            .id,
        exact.id);
    expect(
        extractPersonMentions('Herr Müller', [anna, alias])
            .single
            .matches
            .single
            .id,
        alias.id);
  });

  test(
      'a known first name is not reassigned to a different unfamiliar full name',
      () {
    final anna = Person(id: 'anna', name: 'Anna Schmidt');
    final mentions = extractPersonMentions(
        'Anna kam mit meiner Schwester Anna Müller.', [anna]);
    expect(mentions, hasLength(2));
    expect(mentions.first.matches.single.id, anna.id);
    expect(mentions.last.name, 'Anna Müller');
    expect(mentions.last.matches, isEmpty);
  });
}
