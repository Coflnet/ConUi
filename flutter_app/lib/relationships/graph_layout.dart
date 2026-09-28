import 'dart:collection';

import 'family_graph.dart';
import 'relationship_type.dart';

/// Line style a graph edge should be drawn with, independent of layout: every directed
/// type (parent/child and its variants - step, adoptive, grand-, god-, guardian/ward,
/// mentor/mentee) renders as "parent-child", the romantic-tie types as "partner",
/// sibling/half-sibling as "sibling", and everything else (friend, colleague, unknown
/// legacy values, ...) as "other".
enum GraphEdgeKind { parentChild, partner, sibling, other }

GraphEdgeKind edgeKindFor(RelationshipKind kind) {
  final type = kind.known;
  if (type == null) return GraphEdgeKind.other;
  if (type.isDirected) return GraphEdgeKind.parentChild;
  switch (type) {
    case RelationshipType.spouse:
    case RelationshipType.partner:
    case RelationshipType.exPartner:
      return GraphEdgeKind.partner;
    case RelationshipType.sibling:
    case RelationshipType.halfSibling:
      return GraphEdgeKind.sibling;
    default:
      return GraphEdgeKind.other;
  }
}

/// Directed types whose person1 plays the generationally-earlier/"upper" role - used
/// only to decide which side of a directed edge is [GraphLayoutEdge.sourceId] (kept
/// stable regardless of which person happened to be stored as person1/person2).
const Set<RelationshipType> _upperRoles = {
  RelationshipType.parent,
  RelationshipType.grandparent,
  RelationshipType.stepParent,
  RelationshipType.adoptiveParent,
  RelationshipType.godparent,
  RelationshipType.guardian,
  RelationshipType.mentor,
};

/// One generation's worth of vertical shift for a family-tree slot (see
/// [RelationshipGroup]): parents/children shift by one layer, grandparents/
/// grandchildren by two; siblings, partners, other-family and friends-and-others all
/// stay level with the person they are connected to (a godparent, for instance, is not
/// placed as if they were a generation up).
int _layerDeltaFor(RelationshipGroup group) {
  switch (group) {
    case RelationshipGroup.parents:
      return -1;
    case RelationshipGroup.children:
      return 1;
    case RelationshipGroup.grandparents:
      return -2;
    case RelationshipGroup.grandchildren:
      return 2;
    default:
      return 0;
  }
}

/// One positioned person in a [GraphLayout].
class GraphLayoutNode {
  final String id;

  /// Generation relative to the centered person: 0 = center's generation, negative =
  /// ancestors, positive = descendants.
  final int layer;

  /// Position within the layer, left to right.
  final int column;
  final double x;
  final double y;

  /// True when this person has no genealogical (family-tree-slot) path to the center -
  /// only a friendsAndOthers tie connects them - so they are drawn to the side of
  /// their layer instead of interleaved with the family nodes.
  final bool sideOnly;

  const GraphLayoutNode({
    required this.id,
    required this.layer,
    required this.column,
    required this.x,
    required this.y,
    required this.sideOnly,
  });
}

/// One positioned edge in a [GraphLayout]. For a directed type, [sourceId] is always
/// the generationally-earlier/"upper" person (e.g. the parent) so lines are always
/// drawn from the earlier generation toward the later one, regardless of which person
/// was stored as person1/person2.
class GraphLayoutEdge {
  final String id;
  final String sourceId;
  final String targetId;
  final GraphEdgeKind kind;
  final bool isDerived;

  const GraphLayoutEdge({
    required this.id,
    required this.sourceId,
    required this.targetId,
    required this.kind,
    required this.isDerived,
  });
}

class GraphLayout {
  final List<GraphLayoutNode> nodes;
  final List<GraphLayoutEdge> edges;
  final double width;
  final double height;

  const GraphLayout({
    required this.nodes,
    required this.edges,
    required this.width,
    required this.height,
  });

  static const empty = GraphLayout(nodes: [], edges: [], width: 0, height: 0);
}

const double _spacingX = 140;
const double _spacingY = 160;
const double _margin = 70;

class _Neighbor {
  final String id;
  final RelationshipGroup group;
  final GraphEdge edge;
  const _Neighbor(this.id, this.group, this.edge);
}

/// Computes a generations-as-layers layout for the family graph: ancestors above the
/// centered person, descendants below, partners/siblings sharing a layer, and persons
/// reachable only through a friendsAndOthers tie placed to the side of their layer
/// instead of interleaved with the genealogical nodes. Pure and framework-free so it
/// can be called once per graph query and is cheap to unit test.
///
/// Layer assignment runs in two breadth-first passes to resolve a known limitation of
/// a single mixed BFS: when several paths of different length/kind lead to the same
/// person (e.g. a direct partner tie *and* a longer parent chain), whichever edge a
/// plain BFS happens to dequeue first would arbitrarily decide that person's
/// generation. Instead, generation is decided by family edges first: pass 1 is a
/// breadth-first walk using only edges with a non-zero [_layerDeltaFor] (parent/child,
/// grandparent/grandchild, step-/adoptive-/god- variants), so every person reachable
/// through a genealogical chain gets the layer that chain implies. Pass 2 then does a
/// breadth-first walk over *all* remaining edges, seeded from every node pass 1 already
/// placed at once, so a same-layer tie (partner, sibling, other family, friend) can only
/// ever extend outward from an already-decided generation, never override one. Only
/// persons no family chain reaches at all have their layer decided by first-found-wins
/// among those same-layer ties, same as the earlier single-pass algorithm did for
/// everyone.
GraphLayout computeGraphLayout({
  required Iterable<String> personIds,
  required Iterable<GraphEdge> edges,
  required String centerPersonId,
}) {
  final nodeIds = personIds.toSet();
  if (!nodeIds.contains(centerPersonId)) return GraphLayout.empty;

  final adjacency = _buildAdjacency(edges, nodeIds);

  final layer = <String, int>{};
  final order = <String, int>{};
  final sideOnly = <String, bool>{};
  var nextOrder = 0;

  void visit(String id, int atLayer, bool isSideOnly) {
    layer[id] = atLayer;
    order[id] = nextOrder++;
    sideOnly[id] = isSideOnly;
  }

  visit(centerPersonId, 0, false);

  // Pass 1: family edges only.
  final familyQueue = Queue<String>()..add(centerPersonId);
  while (familyQueue.isNotEmpty) {
    final current = familyQueue.removeFirst();
    final currentLayer = layer[current]!;
    for (final neighbor in adjacency[current] ?? const <_Neighbor>[]) {
      if (layer.containsKey(neighbor.id)) continue;
      final delta = _layerDeltaFor(neighbor.group);
      if (delta == 0) continue;
      visit(neighbor.id, currentLayer + delta, false);
      familyQueue.add(neighbor.id);
    }
  }

  // Pass 2: every remaining edge, seeded from all nodes pass 1 already placed.
  final queue = Queue<String>()..addAll(layer.keys);
  while (queue.isNotEmpty) {
    final current = queue.removeFirst();
    final currentLayer = layer[current]!;
    for (final neighbor in adjacency[current] ?? const <_Neighbor>[]) {
      if (layer.containsKey(neighbor.id)) continue;
      final delta = _layerDeltaFor(neighbor.group);
      final isSideOnly = neighbor.group == RelationshipGroup.friendsAndOthers;
      visit(neighbor.id, currentLayer + delta, isSideOnly);
      queue.add(neighbor.id);
    }
  }

  // Defensive: any input node BFS did not reach still gets a position, at the side of
  // the center's own layer, rather than being silently dropped.
  for (final id in nodeIds) {
    if (!layer.containsKey(id)) {
      visit(id, 0, true);
    }
  }

  final layerNodeIds = _groupByLayer(nodeIds, layer, order);
  _applyPartnerAdjacency(layerNodeIds, layer, edges);
  final columns = _finalizeColumns(layerNodeIds, sideOnly);

  final layoutNodes = nodeIds.map((id) {
    final nodeLayer = layer[id]!;
    final layerIds = layerNodeIds[nodeLayer]!;
    final column = columns[id]!;
    return GraphLayoutNode(
      id: id,
      layer: nodeLayer,
      column: column,
      x: (column - (layerIds.length - 1) / 2) * _spacingX,
      y: nodeLayer * _spacingY,
      sideOnly: sideOnly[id] ?? false,
    );
  }).toList();

  final layoutEdges = edges
      .where((edge) => nodeIds.contains(edge.person1Id) && nodeIds.contains(edge.person2Id))
      .map(_normalizeEdge)
      .toList();

  return GraphLayout(
    nodes: layoutNodes,
    edges: layoutEdges,
    width: _computeExtent(layoutNodes, (n) => n.x),
    height: _computeExtent(layoutNodes, (n) => n.y),
  );
}

Map<String, List<_Neighbor>> _buildAdjacency(Iterable<GraphEdge> edges, Set<String> nodeIds) {
  final adjacency = <String, List<_Neighbor>>{};
  void add(String from, String to, GraphEdge edge) {
    final group = groupForKind(edge.kindFrom(to));
    adjacency.putIfAbsent(from, () => []).add(_Neighbor(to, group, edge));
  }

  for (final edge in edges) {
    if (!nodeIds.contains(edge.person1Id) || !nodeIds.contains(edge.person2Id)) continue;
    add(edge.person1Id, edge.person2Id, edge);
    add(edge.person2Id, edge.person1Id, edge);
  }
  return adjacency;
}

Map<int, List<String>> _groupByLayer(
  Set<String> nodeIds,
  Map<String, int> layer,
  Map<String, int> order,
) {
  final byDiscoveryOrder = nodeIds.toList()
    ..sort((a, b) => (order[a] ?? 0).compareTo(order[b] ?? 0));
  final layerNodeIds = <int, List<String>>{};
  for (final id in byDiscoveryOrder) {
    layerNodeIds.putIfAbsent(layer[id]!, () => []).add(id);
  }
  return layerNodeIds;
}

/// Moves each partner's node to be immediately adjacent to their partner within the
/// shared layer, so "partners next to each other" holds even when BFS discovery order
/// separated them.
void _applyPartnerAdjacency(
  Map<int, List<String>> layerNodeIds,
  Map<String, int> layer,
  Iterable<GraphEdge> edges,
) {
  for (final edge in edges) {
    if (groupForKind(edge.kind) != RelationshipGroup.partners) continue;
    if (!layer.containsKey(edge.person1Id) || !layer.containsKey(edge.person2Id)) continue;
    if (layer[edge.person1Id] != layer[edge.person2Id]) continue;

    final layerArr = layerNodeIds[layer[edge.person1Id]!];
    if (layerArr == null) continue;
    final ia = layerArr.indexOf(edge.person1Id);
    final ib = layerArr.indexOf(edge.person2Id);
    if (ia == -1 || ib == -1 || (ia - ib).abs() == 1) continue;

    layerArr.removeAt(ib);
    final newIa = layerArr.indexOf(edge.person1Id);
    layerArr.insert(newIa + 1, edge.person2Id);
  }
}

/// Stable-partitions each layer so side-only nodes trail the genealogically-positioned
/// ones, then assigns column indices.
Map<String, int> _finalizeColumns(
  Map<int, List<String>> layerNodeIds,
  Map<String, bool> sideOnly,
) {
  final columns = <String, int>{};
  for (final entry in layerNodeIds.entries) {
    final main = entry.value.where((id) => !(sideOnly[id] ?? false));
    final side = entry.value.where((id) => sideOnly[id] ?? false);
    final ordered = [...main, ...side];
    layerNodeIds[entry.key] = ordered;
    for (var i = 0; i < ordered.length; i++) {
      columns[ordered[i]] = i;
    }
  }
  return columns;
}

GraphLayoutEdge _normalizeEdge(GraphEdge edge) {
  final kind = edgeKindFor(edge.kind);
  final type = edge.kind.known;
  if (type != null && type.isDirected) {
    final person1IsUpper = _upperRoles.contains(type);
    return GraphLayoutEdge(
      id: edge.id,
      sourceId: person1IsUpper ? edge.person1Id : edge.person2Id,
      targetId: person1IsUpper ? edge.person2Id : edge.person1Id,
      kind: kind,
      isDerived: edge.isDerived,
    );
  }
  return GraphLayoutEdge(
    id: edge.id,
    sourceId: edge.person1Id,
    targetId: edge.person2Id,
    kind: kind,
    isDerived: edge.isDerived,
  );
}

double _computeExtent(List<GraphLayoutNode> nodes, double Function(GraphLayoutNode) accessor) {
  if (nodes.isEmpty) return 0;
  final values = nodes.map(accessor);
  return values.reduce((a, b) => a > b ? a : b) - values.reduce((a, b) => a < b ? a : b) + 2 * _margin;
}
