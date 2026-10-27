import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/models/person.dart';
import 'package:relationship_manager/services/transcript_connections.dart';

void main() {
  test('coordinated role clauses retain the established subject', () {
    for (final text in [
      'John is a colleague of Ben and a friend of Sara.',
      'John ist ein Kollege von Ben und ein Freund von Sara.',
      'John ist der Bruder von Ben, der bei Acme arbeitet und ein Kollege von Sara ist.',
    ]) {
      final result = extractTranscriptConnections(text, []);
      expect(result.connections, hasLength(2), reason: text);
      expect(result.connections.last.person1Name,
          text.contains('Bruder') ? 'Ben' : 'John');
      expect(result.connections.last.person2Name, 'Sara');
    }
  });

  test('address punctuation and company conjunctions preserve complete facts',
      () {
    for (final text in [
      'Clara wohnt in Dr. Müller-Str. 7, 2. OG links, 04109 Leipzig',
      'Clara lives at 17 Main St., Apt. 4B, Bristol',
    ]) {
      final result = extractTranscriptConnections('$text.', []);
      expect(result.facts.single.value, text);
      expect(result.facts.single.sourceText, text);
    }
    final company = extractTranscriptConnections(
        'Clara arbeitet bei Fischer und Söhne, GmbH.', []);
    expect(company.facts.single.value, 'Fischer und Söhne, GmbH');
  });

  test('shared residences stop before another named assertion', () {
    for (final separator in [' und ', ', ']) {
      final result = extractTranscriptConnections(
          'Karl und Lena wohnen zusammen in Berlin${separator}Paul arbeitet bei Bosch.',
          []);
      expect(result.connections, isEmpty);
      expect(result.facts.map((f) => (f.personName, f.value)), [
        ('Karl', 'Karl und Lena wohnen zusammen in Berlin'),
        ('Lena', 'Karl und Lena wohnen zusammen in Berlin'),
        ('Paul', 'Bosch'),
      ]);
      expect(result.facts.last.sourceText, 'Paul arbeitet bei Bosch');
    }
  });

  test('sentence punctuation separates subjects without spaces', () {
    for (final punctuation in ['!', '.']) {
      final result = extractTranscriptConnections(
          'Nora wohnt in Bonn${punctuation}Emil wohnt in Köln.', []);
      expect(result.facts.map((f) => (f.personName, f.value)), [
        ('Nora', 'Nora wohnt in Bonn'),
        ('Emil', 'Emil wohnt in Köln'),
      ]);
    }
    final result = extractTranscriptConnections(
        'Nora wohnt in Bonn?Emil wohnt in Köln.', []);
    expect(result.facts.single.personName, 'Emil');
  });

  test('May in a name or birthday is not a modal claim', () {
    final result = extractTranscriptConnections(
        'Nora was born on May 5, 1990. May works at Acme.',
        [Person(name: 'May')]);
    expect(result.facts.map((f) => (f.personName, f.value)), [
      ('Nora', 'Nora was born on May 5, 1990'),
      ('May', 'Acme'),
    ]);
    expect(extractTranscriptConnections('Nora may work at Acme.', []).facts,
        isEmpty);
  });

  test('uncertainty, alternatives and unrecoverable corrections stay rejected',
      () {
    for (final text in [
      'Nora wohnt in Berlin, eventuell.',
      'Nora lives in Berlin or Hamburg.',
      'Nora works at Acme or Beta.',
      'Nora wohnt in Bonn, nein, woanders.',
      'Wenn Nora in Berlin wohnt, aber Emil wohnt in Köln.',
      'Someone said Nora lives in Berlin, but Emil lives in Cologne.',
    ]) {
      expect(extractTranscriptConnections(text, []).facts, isEmpty,
          reason: text);
    }
  });

  test('supported corrections retain original evidence and replace old value',
      () {
    for (final (text, value) in [
      ('Nora wohnt in Bonn, ich meine in Köln.', 'Nora wohnt in Köln'),
      ('Nora lives in Bonn, no, in Cologne.', 'Nora lives in Cologne'),
    ]) {
      final result = extractTranscriptConnections(text, []);
      expect(result.facts.single.value, value);
      expect(
          result.facts.single.sourceText, text.substring(0, text.length - 1));
    }
  });
}
