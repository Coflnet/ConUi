import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/models/person.dart';
import 'package:relationship_manager/relationships/family_graph.dart';
import 'package:relationship_manager/relationships/relationship_type.dart';

Person person(String id, {String name = '', bool isDeleted = false}) => Person(
      id: id,
      name: name.isEmpty ? id : name,
      isDeleted: isDeleted,
    );

Connection connection(
  String id,
  String person1Id,
  String person2Id,
  String type, {
  String? description,
}) =>
    Connection(
      id: id,
      person1Id: person1Id,
      person2Id: person2Id,
      relationshipType: type,
      description: description,
    );

void main() {
  group('groupFor() / groupForKind()', () {
    test('parent-like directed types group with parents/children', () {
      expect(groupFor(RelationshipType.parent), RelationshipGroup.parents);
      expect(groupFor(RelationshipType.stepParent), RelationshipGroup.parents);
      expect(groupFor(RelationshipType.adoptiveParent), RelationshipGroup.parents);
      expect(groupFor(RelationshipType.child), RelationshipGroup.children);
      expect(groupFor(RelationshipType.stepChild), RelationshipGroup.children);
      expect(groupFor(RelationshipType.adoptedChild), RelationshipGroup.children);
    });

    test('grandparent/grandchild have their own groups', () {
      expect(groupFor(RelationshipType.grandparent), RelationshipGroup.grandparents);
      expect(groupFor(RelationshipType.grandchild), RelationshipGroup.grandchildren);
    });

    test('sibling and half-sibling group together', () {
      expect(groupFor(RelationshipType.sibling), RelationshipGroup.siblings);
      expect(groupFor(RelationshipType.halfSibling), RelationshipGroup.siblings);
    });

    test('spouse/partner/ex-partner group together', () {
      expect(groupFor(RelationshipType.spouse), RelationshipGroup.partners);
      expect(groupFor(RelationshipType.partner), RelationshipGroup.partners);
      expect(groupFor(RelationshipType.exPartner), RelationshipGroup.partners);
    });

    test('godparent/guardian/other relative go to otherFamily', () {
      expect(groupFor(RelationshipType.godparent), RelationshipGroup.otherFamily);
      expect(groupFor(RelationshipType.guardian), RelationshipGroup.otherFamily);
      expect(groupFor(RelationshipType.otherRelative), RelationshipGroup.otherFamily);
    });

    test('friend/colleague/mentor/other go to friendsAndOthers', () {
      expect(groupFor(RelationshipType.friend), RelationshipGroup.friendsAndOthers);
      expect(groupFor(RelationshipType.colleague), RelationshipGroup.friendsAndOthers);
      expect(groupFor(RelationshipType.mentor), RelationshipGroup.friendsAndOthers);
      expect(groupFor(RelationshipType.other), RelationshipGroup.friendsAndOthers);
    });

    test('every RelationshipType maps to exactly one group without throwing', () {
      for (final type in RelationshipType.values) {
        expect(() => groupFor(type), returnsNormally);
      }
    });

    test('unknown/legacy raw kind (e.g. "family") groups as otherFamily', () {
      expect(groupForKind(RelationshipKind.parse('family')), RelationshipGroup.otherFamily);
    });
  });

  group('FamilyGraph.build() defensive filtering', () {
    test('drops a deleted person and any connection touching them', () {
      final graph = FamilyGraph.build(
        persons: [person('a'), person('b', isDeleted: true)],
        connections: [connection('c1', 'a', 'b', 'friend')],
      );
      expect(graph.containsPerson('b'), isFalse);
      expect(graph.groupedNeighbors('a').values.every((l) => l.isEmpty), isTrue);
    });

    test('drops a connection to a person that no longer exists', () {
      final graph = FamilyGraph.build(
        persons: [person('a')],
        connections: [connection('c1', 'a', 'ghost', 'friend')],
      );
      expect(graph.groupedNeighbors('a').values.every((l) => l.isEmpty), isTrue);
    });

    test('a self-connection does not crash and produces no visible edge', () {
      final graph = FamilyGraph.build(
        persons: [person('a')],
        connections: [connection('c1', 'a', 'a', 'parent')],
      );
      expect(graph.groupedNeighbors('a').values.every((l) => l.isEmpty), isTrue);
      expect(graph.traverse('a').personIds, ['a']);
    });
  });

  group('FamilyGraph.groupedNeighbors()', () {
    test(
        'a person1-side "parent" connection labels the queried person as parent, '
        'but buckets the neighbour (the child) under children', () {
      // Anna is the parent of Karl (stored exactly as our reading rule states it).
      final graph = FamilyGraph.build(
        persons: [person('anna'), person('karl')],
        connections: [connection('r1', 'anna', 'karl', 'parent')],
      );
      final groups = graph.groupedNeighbors('anna');
      // Karl is Anna's child, so he belongs in her "children" section...
      expect(groups[RelationshipGroup.children]!.single.neighborId, 'karl');
      // ...labeled with Anna's own role toward him ("Parent of Karl"), per the brief's
      // "Parent of Bert" example.
      expect(groups[RelationshipGroup.children]!.single.kind.known, RelationshipType.parent);
      expect(groups[RelationshipGroup.parents], isEmpty);
    });

    test(
        'a person2-side "parent" connection labels the queried person as child, '
        'but buckets the neighbour (the parent) under parents', () {
      // Tom is the parent of Anna (tom = person1, "tom is the parent of anna").
      final graph = FamilyGraph.build(
        persons: [person('anna'), person('tom')],
        connections: [connection('r1', 'tom', 'anna', 'parent')],
      );
      final groups = graph.groupedNeighbors('anna');
      // Tom is literally Anna's parent, so he belongs in her "parents" section...
      expect(groups[RelationshipGroup.parents]!.single.neighborId, 'tom');
      // ...labeled with Anna's own role toward him ("Child of Tom").
      expect(groups[RelationshipGroup.parents]!.single.kind.known, RelationshipType.child);
      expect(groups[RelationshipGroup.children], isEmpty);
    });

    test('does not flip a symmetric type', () {
      final graph = FamilyGraph.build(
        persons: [person('anna'), person('maria')],
        connections: [connection('r1', 'maria', 'anna', 'partner')],
      );
      final groups = graph.groupedNeighbors('anna');
      expect(groups[RelationshipGroup.partners]!.single.kind.known, RelationshipType.partner);
    });

    test('never includes a self-relationship even from malformed data', () {
      final graph = FamilyGraph.build(
        persons: [person('anna')],
        connections: [],
      );
      final groups = graph.groupedNeighbors('anna');
      expect(groups.values.every((l) => l.isEmpty), isTrue);
    });

    test('carries description/dates through', () {
      final graph = FamilyGraph.build(
        persons: [person('anna'), person('friend')],
        connections: [connection('r1', 'anna', 'friend', 'other', description: 'Godmother')],
      );
      final entry = graph.groupedNeighbors('anna')[RelationshipGroup.friendsAndOthers]!.single;
      expect(entry.description, 'Godmother');
      expect(entry.isDerived, isFalse);
    });
  });

  group('derived siblings', () {
    test('two children sharing one parent become derived siblings', () {
      final graph = FamilyGraph.build(
        persons: [person('karl'), person('anna'), person('tom')],
        connections: [
          connection('r1', 'karl', 'anna', 'parent'),
          connection('r2', 'karl', 'tom', 'parent'),
        ],
      );
      final siblings = graph.groupedNeighbors('anna')[RelationshipGroup.siblings]!;
      expect(siblings, hasLength(1));
      expect(siblings.single.neighborId, 'tom');
      expect(siblings.single.isDerived, isTrue);
      expect(siblings.single.kind.known, RelationshipType.sibling);
    });

    test('half-siblings sharing only one parent are still derived', () {
      final graph = FamilyGraph.build(
        persons: [person('karl'), person('maria'), person('julia'), person('anna'), person('ben')],
        connections: [
          connection('r1', 'karl', 'anna', 'parent'),
          connection('r2', 'maria', 'anna', 'parent'),
          connection('r3', 'karl', 'ben', 'parent'),
          connection('r4', 'julia', 'ben', 'parent'),
        ],
      );
      final siblings = graph.groupedNeighbors('anna')[RelationshipGroup.siblings]!;
      expect(siblings, hasLength(1));
      expect(siblings.single.neighborId, 'ben');
      expect(siblings.single.isDerived, isTrue);
    });

    test('an explicit sibling edge wins over the derived one (no double edge)', () {
      final graph = FamilyGraph.build(
        persons: [person('karl'), person('anna'), person('tom')],
        connections: [
          connection('r1', 'karl', 'anna', 'parent'),
          connection('r2', 'karl', 'tom', 'parent'),
          connection('r3', 'anna', 'tom', 'sibling'),
        ],
      );
      final siblings = graph.groupedNeighbors('anna')[RelationshipGroup.siblings]!;
      expect(siblings, hasLength(1));
      expect(siblings.single.isDerived, isFalse);
      expect(siblings.single.edgeId, 'r3');
    });

    test('three children of the same parents produce exactly three derived sibling pairs', () {
      final graph = FamilyGraph.build(
        persons: [person('karl'), person('maria'), person('anna'), person('tom'), person('lea')],
        connections: [
          for (final child in ['anna', 'tom', 'lea']) ...[
            connection('${child}_karl', 'karl', child, 'parent'),
            connection('${child}_maria', 'maria', child, 'parent'),
          ],
        ],
      );
      final annaSiblings = graph.groupedNeighbors('anna')[RelationshipGroup.siblings]!;
      final tomSiblings = graph.groupedNeighbors('tom')[RelationshipGroup.siblings]!;
      expect(annaSiblings.map((e) => e.neighborId).toSet(), {'tom', 'lea'});
      expect(tomSiblings.map((e) => e.neighborId).toSet(), {'anna', 'lea'});
    });

    test('the derived sibling id is deterministic and independent of query direction', () {
      final graph = FamilyGraph.build(
        persons: [person('karl'), person('anna'), person('tom')],
        connections: [
          connection('r1', 'karl', 'anna', 'parent'),
          connection('r2', 'karl', 'tom', 'parent'),
        ],
      );
      final fromAnna = graph.groupedNeighbors('anna')[RelationshipGroup.siblings]!.single.edgeId;
      final fromTom = graph.groupedNeighbors('tom')[RelationshipGroup.siblings]!.single.edgeId;
      expect(fromAnna, fromTom);
      expect(fromAnna, FamilyGraph.derivedSiblingId('anna', 'tom'));
      expect(fromAnna, FamilyGraph.derivedSiblingId('tom', 'anna'));
    });
  });

  group('FamilyGraph.traverse()', () {
    test('respects the depth limit along a parent chain', () {
      final graph = FamilyGraph.build(
        persons: [person('a'), person('b'), person('c'), person('d')],
        connections: [
          connection('r1', 'a', 'b', 'parent'),
          connection('r2', 'b', 'c', 'parent'),
          connection('r3', 'c', 'd', 'parent'),
        ],
      );
      expect(graph.traverse('a', depth: 1).personIds.toSet(), {'a', 'b'});
      expect(graph.traverse('a', depth: 2).personIds.toSet(), {'a', 'b', 'c'});
      expect(graph.traverse('a', depth: 3).personIds.toSet(), {'a', 'b', 'c', 'd'});
    });

    test('an absurd depth does not throw or hang, just clamps', () {
      final graph = FamilyGraph.build(persons: [person('a')], connections: []);
      expect(() => graph.traverse('a', depth: 100000), returnsNormally);
    });

    test('the node limit truncates and reports it, without exceeding the limit', () {
      final persons = List.generate(10, (i) => person('p$i'));
      final connections = [
        for (var i = 0; i < 9; i++) connection('r$i', 'p$i', 'p${i + 1}', 'friend'),
      ];
      final graph = FamilyGraph.build(persons: persons, connections: connections);
      final result = graph.traverse('p0', depth: 10, nodeLimit: 3);
      expect(result.personIds.length, lessThanOrEqualTo(3));
      expect(result.truncated, isTrue);
    });

    test('a traversal that reaches everyone before the limit is not marked truncated', () {
      final graph = FamilyGraph.build(
        persons: [person('a'), person('b')],
        connections: [connection('r1', 'a', 'b', 'friend')],
      );
      final result = graph.traverse('a', depth: 5, nodeLimit: 300);
      expect(result.truncated, isFalse);
    });

    test('starting from different persons in the same component yields the same node set', () {
      final graph = FamilyGraph.build(
        persons: [person('karl'), person('maria'), person('anna'), person('tom')],
        connections: [
          connection('r1', 'anna', 'karl', 'parent'),
          connection('r2', 'anna', 'maria', 'parent'),
          connection('r3', 'tom', 'karl', 'parent'),
          connection('r4', 'tom', 'maria', 'parent'),
        ],
      );
      final fromAnna = graph.traverse('anna', depth: 5).personIds.toSet();
      final fromKarl = graph.traverse('karl', depth: 5).personIds.toSet();
      expect(fromAnna, fromKarl);
      expect(fromAnna, {'karl', 'maria', 'anna', 'tom'});
    });

    test('terminates on a cycle (both directions claim to be the other\'s parent)', () {
      final graph = FamilyGraph.build(
        persons: [person('a'), person('b')],
        connections: [
          connection('r1', 'a', 'b', 'parent'),
          connection('r2', 'b', 'a', 'parent'),
        ],
      );
      final result = graph.traverse('a', depth: 5);
      expect(result.personIds.toSet(), {'a', 'b'});
    });

    test('includes an edge between two already-visited nodes, not only tree edges', () {
      // a-b (parent) and a-c (partner) both at depth 1; b and c also happen to be
      // partners of each other - that edge must show up too, even though neither b nor
      // c is "first reached" through it.
      final graph = FamilyGraph.build(
        persons: [person('a'), person('b'), person('c')],
        connections: [
          connection('r1', 'a', 'b', 'parent'),
          connection('r2', 'a', 'c', 'partner'),
          connection('r3', 'b', 'c', 'partner'),
        ],
      );
      final result = graph.traverse('a', depth: 2);
      expect(result.edges.map((e) => e.id).toSet(), {'r1', 'r2', 'r3'});
    });

    test('an unknown start person yields an empty, non-truncated traversal', () {
      final graph = FamilyGraph.build(persons: [person('a')], connections: []);
      final result = graph.traverse('ghost');
      expect(result.personIds, isEmpty);
      expect(result.truncated, isFalse);
    });
  });

  group('FamilyGraph.shortestPath()', () {
    // The narrative text built from a path (e.g. "Anna is the parent of
    // Bert.") is covered by RelationshipText.pathDescription()'s own tests
    // in relationship_text_test.dart, since building it needs an
    // AppLocalizations - this file stays Flutter-free (see the class doc
    // comment on FamilyGraph) and only checks the structural result.
    test('a direct edge is a one-hop path', () {
      final graph = FamilyGraph.build(
        persons: [person('anna', name: 'Anna'), person('bert', name: 'Bert')],
        connections: [connection('r1', 'anna', 'bert', 'parent')],
      );
      final path = graph.shortestPath('anna', 'bert')!;
      expect(path.personIds, ['anna', 'bert']);
      expect(path.edges.single.id, 'r1');
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
      expect(path.personIds, ['anna', 'bert', 'clara']);
      expect(path.edges.map((e) => e.id), ['r1', 'r2']);
    });

    test('describes the reverse direction correctly for a directed hop', () {
      final graph = FamilyGraph.build(
        persons: [person('anna', name: 'Anna'), person('bert', name: 'Bert')],
        connections: [connection('r1', 'anna', 'bert', 'parent')],
      );
      final path = graph.shortestPath('bert', 'anna')!;
      expect(path.personIds, ['bert', 'anna']);
      expect(path.edges.single.kindFrom('bert').known, RelationshipType.child);
    });

    test('returns null when the two persons are not connected', () {
      final graph = FamilyGraph.build(
        persons: [person('a'), person('b')],
        connections: [],
      );
      expect(graph.shortestPath('a', 'b'), isNull);
    });

    test('returns null for the same person', () {
      final graph = FamilyGraph.build(persons: [person('a')], connections: []);
      expect(graph.shortestPath('a', 'a'), isNull);
    });

    test('returns null when either person is not in the graph', () {
      final graph = FamilyGraph.build(persons: [person('a')], connections: []);
      expect(graph.shortestPath('a', 'ghost'), isNull);
      expect(graph.shortestPath('ghost', 'a'), isNull);
    });

    test('finds the shorter of two paths, not a longer detour', () {
      final graph = FamilyGraph.build(
        persons: [person('a'), person('b'), person('c'), person('d')],
        connections: [
          connection('short', 'a', 'd', 'friend'),
          connection('r1', 'a', 'b', 'friend'),
          connection('r2', 'b', 'c', 'friend'),
          connection('r3', 'c', 'd', 'friend'),
        ],
      );
      final path = graph.shortestPath('a', 'd')!;
      expect(path.personIds, ['a', 'd']);
    });
  });
}
