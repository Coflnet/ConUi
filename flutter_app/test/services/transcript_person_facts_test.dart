import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/services/transcript_connections.dart';

void main() {
  test('explicit personal facts retain their complete wording and evidence',
      () {
    for (final (name, text) in [
      ('Hugo', 'Hugo wohnte früher in Bonn'),
      ('Hugo', 'Hugo used to live in Bonn'),
      ('Hugo', 'Hugo lived at 17 Main Street'),
      ('Iris', 'Iris ist nach Hamburg gezogen'),
      ('Iris', 'Iris moved to Hamburg'),
      ('Jana', 'Jana zieht nächsten Monat nach Bremen'),
      ('Jana', 'Jana will move to Bremen next month'),
      ('Jana', 'Jana is moving to Bremen next month'),
      ('Eva', 'Eva ist Zahnärztin'),
      ('Eva', 'Eva is a dentist'),
      ('Greta', 'Greta spielt jeden Donnerstag Volleyball'),
      ('Greta', 'Greta plays volleyball every Thursday'),
      ('Greta', 'Greta enjoys hiking'),
      ('Jana', 'Jana hat einen Hund namens Milo'),
      ('Jana', 'Jana has a cat named Milo'),
      ('Mara', 'Mara hat am 12. März 1992 Geburtstag'),
      ('Mara', 'Mara was born on March 12, 1992'),
      ('Mara', 'Mara wurde am 12. März 1992 geboren'),
      ('Noah', 'Noah hat die Telefonnummer 030 123456'),
      ('Noah', 'Noah has the phone number +49 30 123456'),
    ]) {
      final result = extractTranscriptConnections('$text.', []);
      expect(result.connections, isEmpty, reason: text);
      expect(result.facts, hasLength(1), reason: text);
      final fact = result.facts.single;
      expect(fact.personName, name, reason: text);
      expect(fact.value, text, reason: text);
      expect(fact.sourceText, text, reason: text);
      expect(fact.isCompany, isFalse, reason: text);
    }
  });

  test('shared residences attribute the same evidence to both named people',
      () {
    for (final text in [
      'Karl und Lena wohnen zusammen in Berlin',
      'Karl and Lena live together in Berlin',
    ]) {
      final result = extractTranscriptConnections('$text.', []);
      expect(result.connections, isEmpty);
      expect(result.facts.map((fact) => fact.personName), ['Karl', 'Lena']);
      expect(result.facts.map((fact) => fact.value), [text, text]);
      expect(result.facts.map((fact) => fact.sourceText), [text, text]);
    }
  });

  test('new predicates retain relative and coordinated subject scope', () {
    for (final (text, value, source) in [
      (
        'Eva is the sister of Greta, who plays volleyball every Thursday.',
        'Greta plays volleyball every Thursday',
        'who plays volleyball every Thursday'
      ),
      (
        'Eva ist die Schwester von Greta, die Zahnärztin ist.',
        'Greta Zahnärztin ist',
        'die Zahnärztin ist'
      ),
      (
        'Greta works at Acme and has a dog named Milo.',
        'Greta has a dog named Milo',
        'has a dog named Milo'
      ),
      (
        'Greta arbeitet bei Acme und spielt jeden Donnerstag Volleyball.',
        'Greta spielt jeden Donnerstag Volleyball',
        'spielt jeden Donnerstag Volleyball'
      ),
    ]) {
      final result = extractTranscriptConnections(text, []);
      final fact = result.facts.singleWhere((fact) => !fact.isCompany);
      expect(fact.personName, 'Greta', reason: text);
      expect(fact.value, value, reason: text);
      expect(fact.sourceText, source, reason: text);
    }
  });

  test('new categories reject uncertain, negated and unsupported statements',
      () {
    for (final text in [
      'Eva ist keine Zahnärztin.',
      'Eva might be a dentist.',
      'Jana hat vielleicht einen Hund namens Milo.',
      'Jana has a dog named Milo?',
      'She has a dog named Milo.',
      'Greta spielt nicht Volleyball.',
      'Noah hat die Telefonnummer unbekannt.',
      'Eva ist Genie.',
      'Eva is a mystery.',
      'Karl and she live together in Berlin.',
    ]) {
      final result = extractTranscriptConnections(text, []);
      expect(result.facts, isEmpty, reason: text);
      expect(result.connections, isEmpty, reason: text);
    }
  });
}
