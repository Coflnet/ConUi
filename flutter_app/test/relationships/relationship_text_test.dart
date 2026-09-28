import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/l10n/gen/app_localizations_de.dart';
import 'package:relationship_manager/l10n/gen/app_localizations_en.dart';
import 'package:relationship_manager/models/person.dart';
import 'package:relationship_manager/relationships/family_graph.dart';
import 'package:relationship_manager/relationships/relationship_text.dart';
import 'package:relationship_manager/relationships/relationship_type.dart';

void main() {
  final en = AppLocalizationsEn();
  final de = AppLocalizationsDe();

  group('RelationshipText.label()', () {
    test('every known type has a non-empty label, in both languages', () {
      for (final type in RelationshipType.values) {
        expect(RelationshipText.label(en, type), isNotEmpty);
        expect(RelationshipText.label(de, type), isNotEmpty);
      }
    });

    test('labels are distinct per type (no accidental collisions)', () {
      final labels = RelationshipType.values.map((t) => RelationshipText.label(en, t)).toList();
      expect(labels.toSet().length, labels.length);
    });
  });

  group('RelationshipText.labelForRaw()', () {
    test('known raw value uses the typed label', () {
      expect(RelationshipText.labelForRaw(en, 'parent'),
          RelationshipText.label(en, RelationshipType.parent));
    });

    test('unknown legacy raw value ("family") is capitalised as-is, regardless of language', () {
      expect(RelationshipText.labelForRaw(en, 'family'), 'Family');
      expect(RelationshipText.labelForRaw(de, 'family'), 'Family');
    });

    test('empty raw value stays empty', () {
      expect(RelationshipText.labelForRaw(en, ''), '');
    });
  });

  group('RelationshipText.sentence()', () {
    test('matches the brief\'s example: "Anna is the parent of Bert."', () {
      expect(RelationshipText.sentence(en, 'Anna', 'Bert', RelationshipType.parent),
          'Anna is the parent of Bert.');
    });

    test('German: "Anna ist Elternteil von Bert." - gender-neutral, no article', () {
      expect(RelationshipText.sentence(de, 'Anna', 'Bert', RelationshipType.parent),
          'Anna ist Elternteil von Bert.');
    });

    test('works for a symmetric type, in both languages', () {
      expect(RelationshipText.sentence(en, 'Anna', 'Bert', RelationshipType.spouse),
          'Anna is the spouse of Bert.');
      expect(RelationshipText.sentence(de, 'Anna', 'Bert', RelationshipType.spouse),
          'Anna ist verheiratet mit Bert.');
    });

    test('never swaps the two names: person1 is always the subject, person2 always the object', () {
      final sentence = RelationshipText.sentence(en, 'Anna', 'Bert', RelationshipType.parent);
      expect(sentence.indexOf('Anna'), lessThan(sentence.indexOf('Bert')));
    });

    test('describes both directions of a directed relationship correctly', () {
      // "Anna is the parent of Bert" and its inverse "Bert is the child of Anna"
      // describe the exact same fact from each person's own point of view.
      expect(RelationshipText.sentence(en, 'Anna', 'Bert', RelationshipType.parent),
          'Anna is the parent of Bert.');
      expect(RelationshipText.sentence(en, 'Bert', 'Anna', RelationshipType.child),
          'Bert is the child of Anna.');
      expect(RelationshipText.sentence(de, 'Anna', 'Bert', RelationshipType.parent),
          'Anna ist Elternteil von Bert.');
      expect(RelationshipText.sentence(de, 'Bert', 'Anna', RelationshipType.child),
          'Bert ist Kind von Anna.');
    });
  });

  group('RelationshipText.sentenceForRaw()', () {
    test('uses the typed sentence for a known raw value', () {
      expect(
        RelationshipText.sentenceForRaw(en, 'Anna', 'Bert', 'parent'),
        RelationshipText.sentence(en, 'Anna', 'Bert', RelationshipType.parent),
      );
    });

    test('falls back to the capitalised raw value for an unknown type', () {
      expect(RelationshipText.sentenceForRaw(en, 'Anna', 'Bert', 'family'),
          'Anna is the family of Bert.');
      expect(RelationshipText.sentenceForRaw(de, 'Anna', 'Bert', 'family'),
          'Anna ist family von Bert.');
    });
  });

  group('RelationshipText.roleOfLabel()', () {
    test('German phrasing needs no gendered article', () {
      expect(RelationshipText.roleOfLabel(de, RelationshipType.parent, 'Bert'), 'Elternteil von Bert');
      expect(RelationshipText.roleOfLabel(de, RelationshipType.spouse, 'Bert'), 'verheiratet mit Bert');
      expect(RelationshipText.roleOfLabel(de, RelationshipType.godparent, 'Bert'),
          'Patin oder Pate von Bert');
    });
  });

  group('RelationshipText.groupLabel()', () {
    test('every group has a non-empty, distinct label', () {
      final labels = RelationshipGroup.values.map((g) => RelationshipText.groupLabel(en, g)).toList();
      expect(labels, everyElement(isNotEmpty));
      expect(labels.toSet().length, labels.length);
    });
  });

  group('RelationshipText.pathDescription()', () {
    Person person(String id, {String? name}) => Person(id: id, name: name ?? id);
    Connection connection(String id, String p1, String p2, String type) => Connection(
          id: id,
          person1Id: p1,
          person2Id: p2,
          relationshipType: type,
        );

    test('a direct edge is a one-hop narrative', () {
      final graph = FamilyGraph.build(
        persons: [person('anna', name: 'Anna'), person('bert', name: 'Bert')],
        connections: [connection('r1', 'anna', 'bert', 'parent')],
      );
      final path = graph.shortestPath('anna', 'bert')!;
      expect(RelationshipText.pathDescription(en, graph, path), 'Anna is the parent of Bert.');
      expect(RelationshipText.pathDescription(de, graph, path), 'Anna ist Elternteil von Bert.');
    });

    test('chains a multi-hop path into one narrative, matching the reading rule per hop', () {
      final graph = FamilyGraph.build(
        persons: [
          person('anna', name: 'Anna'),
          person('bert', name: 'Bert'),
          person('clara', name: 'Clara'),
        ],
        connections: [
          connection('r1', 'anna', 'bert', 'parent'),
          connection('r2', 'bert', 'clara', 'spouse'),
        ],
      );
      final path = graph.shortestPath('anna', 'clara')!;
      expect(RelationshipText.pathDescription(en, graph, path),
          'Anna is the parent of Bert, Bert is the spouse of Clara.');
    });

    test('describes the reverse direction correctly for a directed hop', () {
      final graph = FamilyGraph.build(
        persons: [person('anna', name: 'Anna'), person('bert', name: 'Bert')],
        connections: [connection('r1', 'anna', 'bert', 'parent')],
      );
      final path = graph.shortestPath('bert', 'anna')!;
      expect(RelationshipText.pathDescription(en, graph, path), 'Bert is the child of Anna.');
    });
  });
}
