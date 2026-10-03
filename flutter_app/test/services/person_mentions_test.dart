import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/models/person.dart';
import 'package:relationship_manager/services/person_mentions.dart';

void main() {
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
