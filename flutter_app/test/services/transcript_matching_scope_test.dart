import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/services/transcript_connections.dart';

void main() {
  test('object relatives cannot become facts about the human subject', () {
    for (final text in [
      'Anna has a dog named Milo, who is the friend of Ben.',
      'Anna works at Atlas, which mentors Ben.',
      'Anna works at Atlas, who mentors Ben.',
      'Anna lives in Berlin, which is the friend of Ben.',
      'Anna bought a new car, which mentors Ben.',
      'Anna plays tennis, which is the friend of Ben.',
    ]) {
      final result = extractTranscriptConnections(text, []);
      expect(result.connections, isEmpty, reason: text);
      expect(result.facts, hasLength(1), reason: text);
    }
    final pet = extractTranscriptConnections(
        'Anna hat einen Hund namens Milo, der in Berlin wohnt.', []);
    expect(pet.facts, hasLength(1));
    final human = extractTranscriptConnections(
        'Anna adopted Ben, which mentors Clara and lives in Berlin.', []);
    expect(human.connections, hasLength(1));
    expect(human.facts, isEmpty);
  });

  test('comma conjunctions separate explicit and implicit human predicates',
      () {
    for (final text in [
      'Anna mentors Ben, and Clara teaches David.',
      'Anna betreut Ben als Mentorin, und Clara unterrichtet David.',
    ]) {
      final result = extractTranscriptConnections(text, []);
      expect(result.connections.map((c) => (c.person1Name, c.person2Name)),
          [('Anna', 'Ben'), ('Clara', 'David')],
          reason: text);
    }
    final result = extractTranscriptConnections(
        'Anna works at Atlas, and lives in Berlin, and mentors Ben.', []);
    expect(result.facts.map((f) => f.value), ['Atlas', 'Anna lives in Berlin']);
    expect(result.connections.single.person1Name, 'Anna');
    expect(result.connections.single.person2Name, 'Ben');
  });

  test('contrasts preserve retractions and split independent named assertions',
      () {
    for (final text in [
      'Anna is the friend of Ben, but not really.',
      'Anna is the father of Ben, but only in the play.',
      'Anna ist die Freundin von Ben, aber nicht wirklich.',
      'Someone said Anna is the friend of Ben, but Clara mentors David.',
      'If Anna is the friend of Ben, but Clara mentors David.',
      'Anna is the friend of Ben, but Clara mentors David?',
    ]) {
      expect(extractTranscriptConnections(text, []).connections, isEmpty,
          reason: text);
    }
    final result = extractTranscriptConnections(
        'Nora wohnt nicht in Bonn, aber Emil wohnt in Köln.', []);
    expect(result.facts.map((f) => (f.personName, f.value)),
        [('Emil', 'Emil wohnt in Köln')]);
    final independent = extractTranscriptConnections(
        'Anna is the mother of Ben, but Clara mentors David.', []);
    expect(independent.connections, hasLength(2));
  });
}
