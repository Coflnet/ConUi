import 'package:collection/collection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/relationships/family_graph.dart';
import 'package:relationship_manager/relationships/graph_layout.dart';
import 'package:relationship_manager/relationships/relationship_type.dart';

GraphEdge edge(
  String id,
  String person1Id,
  String person2Id,
  RelationshipType type, {
  bool isDerived = false,
}) =>
    GraphEdge(
      id: id,
      person1Id: person1Id,
      person2Id: person2Id,
      kind: RelationshipKind.of(type),
      isDerived: isDerived,
    );

GraphLayoutNode? findNode(GraphLayout layout, String id) =>
    layout.nodes.where((n) => n.id == id).firstOrNull;

void main() {
  group('edgeKindFor()', () {
    test('every directed type renders as parent-child', () {
      for (final type in RelationshipType.values.where((t) => t.isDirected)) {
        expect(edgeKindFor(RelationshipKind.of(type)), GraphEdgeKind.parentChild, reason: type.name);
      }
    });

    test('spouse/partner/ex-partner render as partner', () {
      for (final type in [RelationshipType.spouse, RelationshipType.partner, RelationshipType.exPartner]) {
        expect(edgeKindFor(RelationshipKind.of(type)), GraphEdgeKind.partner);
      }
    });

    test('sibling/half-sibling render as sibling', () {
      expect(edgeKindFor(RelationshipKind.of(RelationshipType.sibling)), GraphEdgeKind.sibling);
      expect(edgeKindFor(RelationshipKind.of(RelationshipType.halfSibling)), GraphEdgeKind.sibling);
    });

    test('friend/colleague/other and unknown raw values render as other', () {
      expect(edgeKindFor(RelationshipKind.of(RelationshipType.friend)), GraphEdgeKind.other);
      expect(edgeKindFor(RelationshipKind.parse('family')), GraphEdgeKind.other);
    });
  });

  group('computeGraphLayout()', () {
    test('places the centered person at layer 0', () {
      final layout = computeGraphLayout(personIds: ['c'], edges: [], centerPersonId: 'c');
      expect(layout.nodes, hasLength(1));
      expect(layout.nodes.single.id, 'c');
      expect(layout.nodes.single.layer, 0);
      expect(layout.nodes.single.x, 0);
      expect(layout.nodes.single.y, 0);
      expect(layout.nodes.single.sideOnly, isFalse);
    });

    test('returns an empty layout if the centered person is not among the nodes', () {
      final layout = computeGraphLayout(personIds: ['a'], edges: [], centerPersonId: 'missing');
      expect(layout.nodes, isEmpty);
      expect(layout.edges, isEmpty);
      expect(layout.width, 0);
      expect(layout.height, 0);
    });

    group('simple family: grandparents -> parents -> centered person -> children', () {
      final nodes = ['gp', 'p', 'c', 'ch'];
      final edges = [
        edge('e1', 'p', 'c', RelationshipType.parent), // p is c's parent
        edge('e2', 'gp', 'p', RelationshipType.parent), // gp is p's parent
        edge('e3', 'c', 'ch', RelationshipType.parent), // c is ch's parent
      ];
      final layout = computeGraphLayout(personIds: nodes, edges: edges, centerPersonId: 'c');
      int? layerOf(String id) => findNode(layout, id)?.layer;

      test('puts ancestors above (negative layers) and descendants below (positive layers)', () {
        expect(layerOf('c'), 0);
        expect(layerOf('p'), -1);
        expect(layerOf('gp'), -2);
        expect(layerOf('ch'), 1);
      });

      test('normalizes parent-child edges so sourceId is always the parent, targetId the child', () {
        final parentChildEdges = layout.edges.where((e) => e.kind == GraphEdgeKind.parentChild);
        expect(parentChildEdges.map((e) => (e.sourceId, e.targetId)),
            containsAll([('p', 'c'), ('gp', 'p'), ('c', 'ch')]));
      });
    });

    test('a direct grandparent edge places the grandparent two layers up', () {
      final layout = computeGraphLayout(
        personIds: ['c', 'gp'],
        edges: [edge('e1', 'gp', 'c', RelationshipType.grandparent)],
        centerPersonId: 'c',
      );
      expect(findNode(layout, 'gp')?.layer, -2);
    });

    test('keeps partners in the same layer and adjacent, even when BFS discovers a third node in between', () {
      final layout = computeGraphLayout(
        personIds: ['c', 'sibling', 'partner'],
        edges: [
          edge('e1', 'c', 'sibling', RelationshipType.sibling),
          edge('e2', 'c', 'partner', RelationshipType.partner),
        ],
        centerPersonId: 'c',
      );
      final c = findNode(layout, 'c')!;
      final partner = findNode(layout, 'partner')!;
      final sibling = findNode(layout, 'sibling')!;

      expect(c.layer, 0);
      expect(partner.layer, 0);
      expect(sibling.layer, 0);
      expect((c.column - partner.column).abs(), 1);
      expect((c.x - partner.x).abs(), 140);
    });

    test('places explicit siblings in the same layer as the centered person', () {
      final layout = computeGraphLayout(
        personIds: ['c', 's1', 's2'],
        edges: [
          edge('e1', 'c', 's1', RelationshipType.sibling),
          edge('e2', 'c', 's2', RelationshipType.sibling),
        ],
        centerPersonId: 'c',
      );
      expect(findNode(layout, 's1')?.layer, 0);
      expect(findNode(layout, 's2')?.layer, 0);
    });

    test('marks a derived sibling edge through unchanged, for a dashed rendering', () {
      final layout = computeGraphLayout(
        personIds: ['c', 's1'],
        edges: [edge('derived-sibling:c:s1', 'c', 's1', RelationshipType.sibling, isDerived: true)],
        centerPersonId: 'c',
      );
      expect(layout.edges.single.isDerived, isTrue);
      expect(layout.edges.single.kind, GraphEdgeKind.sibling);
    });

    test('places a person reachable only through a friendsAndOthers edge in the centered layer, to the side', () {
      final layout = computeGraphLayout(
        personIds: ['c', 'child', 'friend'],
        edges: [
          edge('e1', 'c', 'child', RelationshipType.parent),
          edge('e2', 'c', 'friend', RelationshipType.friend),
        ],
        centerPersonId: 'c',
      );
      final friend = findNode(layout, 'friend')!;
      final c = findNode(layout, 'c')!;

      expect(friend.layer, 0); // the centre layer, not the child's layer
      expect(friend.sideOnly, isTrue);
      expect(c.sideOnly, isFalse);
      expect(layout.edges.any((e) => e.kind == GraphEdgeKind.other), isTrue);
    });

    test('places a godparent (other-family, non-generational) in the same layer without pushing them to the side', () {
      final layout = computeGraphLayout(
        personIds: ['c', 'god'],
        edges: [edge('e1', 'god', 'c', RelationshipType.godparent)],
        centerPersonId: 'c',
      );
      final god = findNode(layout, 'god')!;
      expect(god.layer, 0);
      expect(god.sideOnly, isFalse);
    });

    test('terminates and stays deterministic for a cycle (both directions claim to be the other\'s parent)', () {
      final layout = computeGraphLayout(
        personIds: ['a', 'b'],
        edges: [
          edge('e1', 'b', 'a', RelationshipType.parent),
          edge('e2', 'a', 'b', RelationshipType.parent),
        ],
        centerPersonId: 'a',
      );
      expect(layout.nodes, hasLength(2));
      // First-found-wins: e1 says "b is a's parent" and is processed first, so it decides.
      expect(findNode(layout, 'b')?.layer, -1);
    });

    test('handles a node reachable as both ancestor and descendant without an infinite loop, keeping the first-assigned layer', () {
      final layout = computeGraphLayout(
        personIds: ['c', 'a'],
        edges: [
          edge('e1', 'a', 'c', RelationshipType.parent),
          edge('e2', 'c', 'a', RelationshipType.parent),
        ],
        centerPersonId: 'c',
      );
      expect(layout.nodes, hasLength(2));
      expect(findNode(layout, 'a')?.layer, -1); // e1 (a is c's parent) seen first
    });

    test(
        'chooses the generation by family edges first, so a same-layer tie discovered earlier in a naive BFS '
        'does not override the genealogical chain (fix for the known single-pass limitation)', () {
      // c's parent is p (family chain -> p should end up at layer -1). c also has a
      // friend edge to p's... no: give p a *friend* edge to a third node "x", and give c
      // a friend edge to x too, so a naive single BFS might reach x at layer 0 via c
      // before ever placing p - but the real family relation (p -> x has no edge here,
      // this scenario instead stresses that p's *own* layer is never second-guessed by
      // a friend edge reached earlier). Concretely: c has a friend edge to p (unusual,
      // but the data can be messy) processed before the parent edge in adjacency order,
      // plus the real parent edge. p must still land at layer -1, not 0.
      final layout = computeGraphLayout(
        personIds: ['c', 'p'],
        edges: [
          edge('friend-edge', 'c', 'p', RelationshipType.friend),
          edge('parent-edge', 'p', 'c', RelationshipType.parent),
        ],
        centerPersonId: 'c',
      );
      expect(findNode(layout, 'p')?.layer, -1);
      expect(findNode(layout, 'p')?.sideOnly, isFalse);
    });

    test('re-centering on a different person yields the same set of nodes/edges, with every layer shifted by a constant', () {
      final nodes = ['gp', 'p', 'c', 'ch'];
      final edges = [
        edge('e1', 'p', 'c', RelationshipType.parent),
        edge('e2', 'gp', 'p', RelationshipType.parent),
        edge('e3', 'c', 'ch', RelationshipType.parent),
      ];
      final centeredOnC = computeGraphLayout(personIds: nodes, edges: edges, centerPersonId: 'c');
      final centeredOnP = computeGraphLayout(personIds: nodes, edges: edges, centerPersonId: 'p');

      expect(centeredOnC.nodes.map((n) => n.id).toSet(), centeredOnP.nodes.map((n) => n.id).toSet());
      expect(centeredOnC.edges.map((e) => e.id).toSet(), centeredOnP.edges.map((e) => e.id).toSet());

      final layerAtC = {for (final n in centeredOnC.nodes) n.id: n.layer};
      final layerAtP = {for (final n in centeredOnP.nodes) n.id: n.layer};
      final shift = layerAtP['c']! - layerAtC['c']!;
      for (final id in nodes) {
        expect(layerAtP[id], layerAtC[id]! + shift);
      }
    });

    test('includes every input node exactly once even if some are unreachable from the center (defensive)', () {
      final layout = computeGraphLayout(personIds: ['c', 'orphan'], edges: [], centerPersonId: 'c');
      expect(layout.nodes.map((n) => n.id).toSet(), {'c', 'orphan'});
      expect(findNode(layout, 'orphan')?.sideOnly, isTrue);
    });

    test('computes a non-zero width/height once there is more than one layer/column', () {
      final layout = computeGraphLayout(
        personIds: ['c', 'p', 'partner'],
        edges: [
          edge('e1', 'p', 'c', RelationshipType.parent),
          edge('e2', 'c', 'partner', RelationshipType.partner),
        ],
        centerPersonId: 'c',
      );
      expect(layout.width, greaterThan(0));
      expect(layout.height, greaterThan(0));
    });

    test('stays well under a second for 200 nodes', () {
      final nodeIds = ['c'];
      final edges = <GraphEdge>[];
      var previousGeneration = ['c'];
      var counter = 0;
      for (var generation = 0; generation < 50 && nodeIds.length < 196; generation++) {
        final nextGeneration = <String>[];
        for (final parentId in previousGeneration) {
          final childId = 'n${counter++}';
          final partnerOfChildId = 'n${counter++}';
          final siblingOfChildId = 'n${counter++}';
          nodeIds.addAll([childId, partnerOfChildId, siblingOfChildId]);
          edges.add(edge('e${counter}p', parentId, childId, RelationshipType.parent));
          edges.add(edge('e${counter}s', childId, siblingOfChildId, RelationshipType.sibling));
          edges.add(edge('e${counter}q', childId, partnerOfChildId, RelationshipType.partner));
          nextGeneration.add(childId);
          if (nodeIds.length >= 196) break;
        }
        previousGeneration = nextGeneration;
      }

      final stopwatch = Stopwatch()..start();
      final layout = computeGraphLayout(personIds: nodeIds, edges: edges, centerPersonId: 'c');
      stopwatch.stop();

      expect(layout.nodes.length, nodeIds.length);
      expect(stopwatch.elapsedMilliseconds, lessThan(1000));
    });
  });
}
