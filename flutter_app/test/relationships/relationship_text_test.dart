import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/relationships/relationship_text.dart';
import 'package:relationship_manager/relationships/relationship_type.dart';

void main() {
  group('RelationshipText.label()', () {
    test('every known type has a non-empty label', () {
      for (final type in RelationshipType.values) {
        expect(RelationshipText.label(type), isNotEmpty);
      }
    });

    test('labels are distinct per type (no accidental collisions)', () {
      final labels = RelationshipType.values.map(RelationshipText.label).toList();
      expect(labels.toSet().length, labels.length);
    });
  });

  group('RelationshipText.labelForRaw()', () {
    test('known raw value uses the typed label', () {
      expect(RelationshipText.labelForRaw('parent'), RelationshipText.label(RelationshipType.parent));
    });

    test('unknown legacy raw value ("family") is capitalised as-is', () {
      expect(RelationshipText.labelForRaw('family'), 'Family');
    });

    test('empty raw value stays empty', () {
      expect(RelationshipText.labelForRaw(''), '');
    });
  });

  group('RelationshipText.sentence()', () {
    test('matches the brief\'s example: "Anna is the parent of Bert."', () {
      expect(RelationshipText.sentence('Anna', 'Bert', RelationshipType.parent), 'Anna is the parent of Bert.');
    });

    test('works for a symmetric type', () {
      expect(RelationshipText.sentence('Anna', 'Bert', RelationshipType.spouse), 'Anna is the spouse of Bert.');
    });

    test('never swaps the two names: person1 is always the subject, person2 always the object', () {
      final sentence = RelationshipText.sentence('Anna', 'Bert', RelationshipType.parent);
      expect(sentence.indexOf('Anna'), lessThan(sentence.indexOf('Bert')));
    });
  });

  group('RelationshipText.sentenceForRaw()', () {
    test('uses the typed sentence for a known raw value', () {
      expect(
        RelationshipText.sentenceForRaw('Anna', 'Bert', 'parent'),
        RelationshipText.sentence('Anna', 'Bert', RelationshipType.parent),
      );
    });

    test('falls back to the capitalised raw value for an unknown type', () {
      expect(RelationshipText.sentenceForRaw('Anna', 'Bert', 'family'), 'Anna is the family of Bert.');
    });
  });
}
