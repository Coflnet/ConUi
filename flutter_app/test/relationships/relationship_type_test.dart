import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/relationships/relationship_type.dart';

({String person1Id, String person2Id, String relationshipType}) existing(
        String p1, String p2, String type) =>
    (person1Id: p1, person2Id: p2, relationshipType: type);

void main() {
  group('RelationshipType.isDirected / isSymmetric', () {
    const directed = {
      RelationshipType.parent,
      RelationshipType.child,
      RelationshipType.grandparent,
      RelationshipType.grandchild,
      RelationshipType.stepParent,
      RelationshipType.stepChild,
      RelationshipType.adoptiveParent,
      RelationshipType.adoptedChild,
      RelationshipType.godparent,
      RelationshipType.godchild,
      RelationshipType.guardian,
      RelationshipType.ward,
      RelationshipType.mentor,
      RelationshipType.mentee,
    };

    for (final type in RelationshipType.values) {
      final shouldBeDirected = directed.contains(type);
      test('$type isDirected == $shouldBeDirected', () {
        expect(type.isDirected, shouldBeDirected);
        expect(type.isSymmetric, !shouldBeDirected);
      });
    }
  });

  group('inverseOf()', () {
    const pairs = {
      RelationshipType.parent: RelationshipType.child,
      RelationshipType.grandparent: RelationshipType.grandchild,
      RelationshipType.stepParent: RelationshipType.stepChild,
      RelationshipType.adoptiveParent: RelationshipType.adoptedChild,
      RelationshipType.godparent: RelationshipType.godchild,
      RelationshipType.guardian: RelationshipType.ward,
      RelationshipType.mentor: RelationshipType.mentee,
    };

    pairs.forEach((a, b) {
      test('$a <-> $b', () {
        expect(inverseOf(a), b);
        expect(inverseOf(b), a);
      });
    });

    test('inverseOf is its own inverse (double inverse is identity) for every type', () {
      for (final type in RelationshipType.values) {
        expect(inverseOf(inverseOf(type)), type);
      }
    });

    for (final type in RelationshipType.values.where((t) => t.isSymmetric)) {
      test('$type is its own inverse (symmetric)', () {
        expect(inverseOf(type), type);
      });
    }
  });

  group('RelationshipType.tryParse() / storageValue', () {
    test('round-trips every known type through its storage string', () {
      for (final type in RelationshipType.values) {
        expect(RelationshipType.tryParse(type.storageValue), type);
      }
    });

    // Backwards compatibility: the pre-vocabulary "Add Connection" dialog wrote these
    // exact strings; they must keep resolving to the matching known type.
    const legacyMatches = {
      'friend': RelationshipType.friend,
      'colleague': RelationshipType.colleague,
      'partner': RelationshipType.partner,
      'spouse': RelationshipType.spouse,
      'parent': RelationshipType.parent,
      'child': RelationshipType.child,
      'sibling': RelationshipType.sibling,
      'acquaintance': RelationshipType.acquaintance,
      'mentor': RelationshipType.mentor,
      'other': RelationshipType.other,
    };
    legacyMatches.forEach((raw, type) {
      test('legacy value "$raw" still parses to $type', () {
        expect(RelationshipType.tryParse(raw), type);
      });
    });

    test('the legacy "family" value has no matching known type (stays unknown/raw)', () {
      expect(RelationshipType.tryParse('family'), isNull);
    });

    test('arbitrary free text does not parse', () {
      expect(RelationshipType.tryParse('best friends forever'), isNull);
      expect(RelationshipType.tryParse(''), isNull);
    });
  });

  group('RelationshipKind', () {
    test('parse() of a known value exposes it as known', () {
      final kind = RelationshipKind.parse('parent');
      expect(kind.isKnown, isTrue);
      expect(kind.known, RelationshipType.parent);
      expect(kind.raw, 'parent');
    });

    test('parse() of an unknown value (legacy "family") is unknown and symmetric', () {
      final kind = RelationshipKind.parse('family');
      expect(kind.isKnown, isFalse);
      expect(kind.known, isNull);
      expect(kind.isSymmetric, isTrue);
      expect(kind.raw, 'family');
    });

    test('of() built from a RelationshipType stores the type name as raw', () {
      final kind = RelationshipKind.of(RelationshipType.grandparent);
      expect(kind.raw, 'grandparent');
      expect(kind.known, RelationshipType.grandparent);
    });

    test('inverse of a directed known kind flips to the inverse type', () {
      final kind = RelationshipKind.of(RelationshipType.parent);
      expect(kind.inverse.known, RelationshipType.child);
    });

    test('inverse of a symmetric known kind is unchanged', () {
      final kind = RelationshipKind.of(RelationshipType.spouse);
      expect(kind.inverse, kind);
    });

    test('inverse of an unknown kind is unchanged (never guesses a direction)', () {
      final kind = RelationshipKind.parse('family');
      expect(kind.inverse, kind);
      expect(kind.inverse.raw, 'family');
    });

    test('equality/hashCode are based on the raw stored value', () {
      expect(RelationshipKind.parse('parent'), RelationshipKind.parse('parent'));
      expect(RelationshipKind.parse('parent') == RelationshipKind.parse('child'), isFalse);
      expect(RelationshipKind.parse('parent').hashCode, RelationshipKind.parse('parent').hashCode);
    });
  });

  group('relationshipKindFrom()', () {
    test('returns the stored kind unchanged when viewed from person1', () {
      final kind = relationshipKindFrom(
        person1Id: 'anna',
        person2Id: 'bert',
        relationshipType: 'parent',
        viewerPersonId: 'anna',
      );
      expect(kind.known, RelationshipType.parent);
    });

    test('flips a directed type to its inverse when viewed from person2', () {
      final kind = relationshipKindFrom(
        person1Id: 'anna',
        person2Id: 'bert',
        relationshipType: 'parent',
        viewerPersonId: 'bert',
      );
      expect(kind.known, RelationshipType.child);
    });

    test('does not flip a symmetric type when viewed from person2', () {
      final kind = relationshipKindFrom(
        person1Id: 'anna',
        person2Id: 'bert',
        relationshipType: 'spouse',
        viewerPersonId: 'bert',
      );
      expect(kind.known, RelationshipType.spouse);
    });

    test('does not flip an unknown/legacy type when viewed from person2', () {
      final kind = relationshipKindFrom(
        person1Id: 'anna',
        person2Id: 'bert',
        relationshipType: 'family',
        viewerPersonId: 'bert',
      );
      expect(kind.raw, 'family');
    });

    test('a self-connection (viewer matches both sides) returns the stored kind unchanged', () {
      final kind = relationshipKindFrom(
        person1Id: 'anna',
        person2Id: 'anna',
        relationshipType: 'parent',
        viewerPersonId: 'anna',
      );
      expect(kind.known, RelationshipType.parent);
    });
  });

  group('isDuplicateConnection()', () {
    test('detects an exact duplicate in the same direction', () {
      final result = isDuplicateConnection(
        existing: [existing('anna', 'bert', 'parent')],
        person1Id: 'anna',
        person2Id: 'bert',
        type: RelationshipType.parent,
      );
      expect(result, isTrue);
    });

    test('detects "A is parent of B" as a duplicate of "B is child of A"', () {
      final result = isDuplicateConnection(
        existing: [existing('bert', 'anna', 'child')],
        person1Id: 'anna',
        person2Id: 'bert',
        type: RelationshipType.parent,
      );
      expect(result, isTrue);
    });

    test('detects a symmetric duplicate regardless of stored person order', () {
      final result = isDuplicateConnection(
        existing: [existing('bert', 'anna', 'spouse')],
        person1Id: 'anna',
        person2Id: 'bert',
        type: RelationshipType.spouse,
      );
      expect(result, isTrue);
    });

    test('does not flag a different type between the same two people as a duplicate', () {
      final result = isDuplicateConnection(
        existing: [existing('anna', 'bert', 'friend')],
        person1Id: 'anna',
        person2Id: 'bert',
        type: RelationshipType.parent,
      );
      expect(result, isFalse);
    });

    test('does not flag connections between unrelated people', () {
      final result = isDuplicateConnection(
        existing: [existing('anna', 'carl', 'parent')],
        person1Id: 'anna',
        person2Id: 'bert',
        type: RelationshipType.parent,
      );
      expect(result, isFalse);
    });

    test('a self-connection request is never a duplicate (caller rejects separately)', () {
      final result = isDuplicateConnection(
        existing: [existing('anna', 'bert', 'parent')],
        person1Id: 'anna',
        person2Id: 'anna',
        type: RelationshipType.parent,
      );
      expect(result, isFalse);
    });

    test('an existing self-loop connection in the list is ignored safely', () {
      final result = isDuplicateConnection(
        existing: [existing('anna', 'anna', 'parent')],
        person1Id: 'anna',
        person2Id: 'bert',
        type: RelationshipType.parent,
      );
      expect(result, isFalse);
    });

    test('matches an unknown/legacy raw type stored the other way round', () {
      final result = isDuplicateConnection(
        existing: [existing('bert', 'anna', 'family')],
        person1Id: 'anna',
        person2Id: 'bert',
        type: RelationshipType.otherRelative,
      );
      // "family" is unknown/symmetric and unrelated to the known otherRelative type -
      // different raw values must never be conflated into a false duplicate.
      expect(result, isFalse);
    });

    test('empty existing list never reports a duplicate', () {
      final result = isDuplicateConnection(
        existing: const [],
        person1Id: 'anna',
        person2Id: 'bert',
        type: RelationshipType.parent,
      );
      expect(result, isFalse);
    });
  });
}
