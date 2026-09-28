import 'dart:collection';

import '../models/person.dart';
import 'relationship_text.dart';
import 'relationship_type.dart';

/// Display grouping for a person's neighbours (see [FamilyGraph.groupedNeighbors]).
/// Deliberately coarser than [RelationshipType]: several types collapse into the same
/// group (e.g. a step-parent groups with a parent) so the person-detail screen shows a
/// short, family-tree-shaped list rather than one section per type.
enum RelationshipGroup {
  parents,
  children,
  grandparents,
  grandchildren,
  siblings,
  partners,
  otherFamily,
  friendsAndOthers,
}

/// Which [RelationshipGroup] a known type belongs to. A judgement call, not a fact
/// derivable from the vocabulary itself: step-parents/adoptive parents are grouped
/// with parents (and their inverses with children) because they fill the same slot in
/// a family tree; godparent/guardian and their inverses, plus "other relative", go to
/// [RelationshipGroup.otherFamily] since they are family-adjacent but not a
/// generational slot; mentor/mentee and the non-family symmetric types go to
/// [RelationshipGroup.friendsAndOthers].
RelationshipGroup groupFor(RelationshipType type) {
  switch (type) {
    case RelationshipType.parent:
    case RelationshipType.stepParent:
    case RelationshipType.adoptiveParent:
      return RelationshipGroup.parents;
    case RelationshipType.child:
    case RelationshipType.stepChild:
    case RelationshipType.adoptedChild:
      return RelationshipGroup.children;
    case RelationshipType.grandparent:
      return RelationshipGroup.grandparents;
    case RelationshipType.grandchild:
      return RelationshipGroup.grandchildren;
    case RelationshipType.sibling:
    case RelationshipType.halfSibling:
      return RelationshipGroup.siblings;
    case RelationshipType.spouse:
    case RelationshipType.partner:
    case RelationshipType.exPartner:
      return RelationshipGroup.partners;
    case RelationshipType.godparent:
    case RelationshipType.godchild:
    case RelationshipType.guardian:
    case RelationshipType.ward:
    case RelationshipType.otherRelative:
      return RelationshipGroup.otherFamily;
    case RelationshipType.mentor:
    case RelationshipType.mentee:
    case RelationshipType.friend:
    case RelationshipType.colleague:
    case RelationshipType.neighbour:
    case RelationshipType.acquaintance:
    case RelationshipType.other:
      return RelationshipGroup.friendsAndOthers;
  }
}

/// [groupFor] for a possibly-unknown/legacy raw type (see [RelationshipKind]). Unknown
/// values (in practice just the legacy "family" value - see `relationship_type.dart`)
/// go to [RelationshipGroup.otherFamily] rather than [RelationshipGroup.friendsAndOthers],
/// since that is the only free-text value the old UI ever wrote and its name suggests
/// family, not a friend/acquaintance tie.
RelationshipGroup groupForKind(RelationshipKind kind) {
  final type = kind.known;
  return type == null ? RelationshipGroup.otherFamily : groupFor(type);
}

/// One edge of the graph in its stored orientation: `person1Id` is the `<kind>` of
/// `person2Id`, per the app-wide reading rule. Used both for edges backed by a real
/// [Connection] (`isDerived == false`, [id] is the connection id) and for derived
/// sibling edges that exist only in this view (`isDerived == true`, [id] is a
/// deterministic id built from the two person ids, see [FamilyGraph]).
class GraphEdge {
  final String id;
  final String person1Id;
  final String person2Id;
  final RelationshipKind kind;
  final bool isDerived;
  final String? description;
  final DateTime? startDate;
  final DateTime? endDate;
  final String? originEventId;

  const GraphEdge({
    required this.id,
    required this.person1Id,
    required this.person2Id,
    required this.kind,
    required this.isDerived,
    this.description,
    this.startDate,
    this.endDate,
    this.originEventId,
  });

  /// The id of the person on the other side of this edge from [personId]. [personId]
  /// must be one of [person1Id]/[person2Id].
  String otherPersonId(String personId) =>
      personId == person1Id ? person2Id : person1Id;

  /// This edge's kind as seen from [personId] (must be [person1Id] or [person2Id]).
  RelationshipKind kindFrom(String personId) => relationshipKindFrom(
        person1Id: person1Id,
        person2Id: person2Id,
        relationshipType: kind.raw,
        viewerPersonId: personId,
      );
}

/// One neighbour of a queried person. [kind] is the *queried person's own* role
/// toward [neighborId] (see [GraphEdge.kindFrom]), e.g. `parent` when the queried
/// person is the neighbour's parent - ready to build a label like "Parent of Bert"
/// without the caller having to know which side of the underlying connection it came
/// from. The entry is bucketed (see [FamilyGraph.groupedNeighbors]) by the *neighbour's*
/// own role instead - the inverse of [kind] for a directed type, e.g. this entry lands
/// in [RelationshipGroup.children] because the neighbour, from their own point of view,
/// is a child. That is what makes a person's "Children" section list the people they
/// are a parent of, and their "Parents" section list the people who are their parents -
/// the ordinary meaning of those words - while each entry's own label still spells out
/// the queried person's precise role (parent vs. step-parent vs. adoptive parent, ...).
class PersonRelationshipView {
  final String edgeId;
  final String neighborId;
  final RelationshipKind kind;
  final bool isDerived;
  final String? description;
  final DateTime? startDate;
  final DateTime? endDate;
  final String? originEventId;

  const PersonRelationshipView({
    required this.edgeId,
    required this.neighborId,
    required this.kind,
    required this.isDerived,
    this.description,
    this.startDate,
    this.endDate,
    this.originEventId,
  });
}

/// Result of [FamilyGraph.traverse]: everyone reached from the start person within the
/// requested depth and node limit, plus every edge among them (not only the edges that
/// were used to first reach a node - e.g. a partner edge between two already-visited
/// people is included too), and whether the node limit cut the traversal short.
class GraphTraversal {
  final List<String> personIds;
  final List<GraphEdge> edges;
  final bool truncated;

  const GraphTraversal({
    required this.personIds,
    required this.edges,
    required this.truncated,
  });
}

/// The shortest chain of edges connecting two persons, with a human-readable narrative
/// built by chaining [RelationshipText.sentenceFragment]/[RelationshipText.sentenceFragmentForRaw]
/// per hop, e.g. "Anna is the parent of Bert, Bert is the spouse of Clara."
class RelationshipPath {
  final List<String> personIds;
  final List<GraphEdge> edges;
  final String description;

  const RelationshipPath({
    required this.personIds,
    required this.edges,
    required this.description,
  });
}

/// Builds a family graph from the full list of persons and connections and answers
/// grouped-neighbours, breadth-first-traversal and shortest-path queries over it. The
/// graph can be explored starting from any person - nobody is a privileged root.
///
/// Deleted persons and connections referencing a person that no longer exists are
/// dropped when the graph is built, never surfaced later. A connection from a person to
/// themselves is dropped too (it carries no information for a family tree); traversal
/// and shortest-path still tolerate cycles elsewhere in the data via their visited sets.
class FamilyGraph {
  final Map<String, Person> _personsById;
  final Map<String, List<GraphEdge>> _edgesByPerson;

  FamilyGraph._(this._personsById, this._edgesByPerson);

  factory FamilyGraph.build({
    required Iterable<Person> persons,
    required Iterable<Connection> connections,
  }) {
    final personsById = <String, Person>{
      for (final person in persons)
        if (!person.isDeleted) person.id: person,
    };

    final explicitEdges = <GraphEdge>[
      for (final connection in connections)
        if (connection.person1Id != connection.person2Id &&
            personsById.containsKey(connection.person1Id) &&
            personsById.containsKey(connection.person2Id))
          GraphEdge(
            id: connection.id,
            person1Id: connection.person1Id,
            person2Id: connection.person2Id,
            kind: RelationshipKind.parse(connection.relationshipType),
            isDerived: false,
            description: connection.description,
            startDate: connection.startDate,
            endDate: connection.endDate,
            originEventId: connection.originEventId,
          ),
    ];

    final allEdges = [
      ...explicitEdges,
      ..._deriveSiblingEdges(explicitEdges),
    ];

    final edgesByPerson = <String, List<GraphEdge>>{};
    for (final edge in allEdges) {
      edgesByPerson.putIfAbsent(edge.person1Id, () => []).add(edge);
      edgesByPerson.putIfAbsent(edge.person2Id, () => []).add(edge);
    }

    return FamilyGraph._(personsById, edgesByPerson);
  }

  /// Siblings derived from shared parents (see class doc on [FamilyGraph] and the
  /// "Derived siblings" rule in the work package): any two persons who are both the
  /// `person2Id` of a `parent` edge from the same `person1Id` (i.e. share at least one
  /// parent) become a derived `sibling` edge between them, unless an explicit
  /// sibling/half-sibling edge already connects that exact pair - an entered
  /// connection always wins over a derived one, so there is never a double edge. The
  /// derived edge's id is deterministic and independent of person order, so
  /// re-deriving it from a graph centered on either sibling yields the same id and it
  /// counts as one hop like any other edge.
  static List<GraphEdge> _deriveSiblingEdges(List<GraphEdge> explicitEdges) {
    final childrenByParent = <String, Set<String>>{};
    for (final edge in explicitEdges) {
      final type = edge.kind.known;
      if (type == RelationshipType.parent) {
        childrenByParent.putIfAbsent(edge.person1Id, () => {}).add(edge.person2Id);
      } else if (type == RelationshipType.child) {
        childrenByParent.putIfAbsent(edge.person2Id, () => {}).add(edge.person1Id);
      }
    }

    final explicitSiblingPairs = <String>{};
    for (final edge in explicitEdges) {
      final type = edge.kind.known;
      if (type == RelationshipType.sibling || type == RelationshipType.halfSibling) {
        explicitSiblingPairs.add(_pairKey(edge.person1Id, edge.person2Id));
      }
    }

    final derived = <String, GraphEdge>{};
    for (final children in childrenByParent.values) {
      final childList = children.toList();
      for (var i = 0; i < childList.length; i++) {
        for (var j = i + 1; j < childList.length; j++) {
          final a = childList[i];
          final b = childList[j];
          if (explicitSiblingPairs.contains(_pairKey(a, b))) continue;
          final id = derivedSiblingId(a, b);
          derived[id] = GraphEdge(
            id: id,
            person1Id: a.compareTo(b) <= 0 ? a : b,
            person2Id: a.compareTo(b) <= 0 ? b : a,
            kind: RelationshipKind.of(RelationshipType.sibling),
            isDerived: true,
          );
        }
      }
    }
    return derived.values.toList();
  }

  static String _pairKey(String a, String b) =>
      a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a';

  /// Deterministic id for the derived sibling edge between [a] and [b], stable
  /// regardless of argument order.
  static String derivedSiblingId(String a, String b) =>
      'derived-sibling:${_pairKey(a, b)}';

  Person? personById(String id) => _personsById[id];

  bool containsPerson(String id) => _personsById.containsKey(id);

  Iterable<Person> get persons => _personsById.values;

  List<GraphEdge> _edgesOf(String personId) => _edgesByPerson[personId] ?? const [];

  /// The neighbours of [personId], grouped for display (see [RelationshipGroup] and
  /// [PersonRelationshipView] for exactly how [personId]'s own role vs. the group
  /// bucket are derived). Deduplicates by (neighbour, kind) - not by edge id - so a
  /// derived sibling edge (whose id is not a real connection id) can never appear
  /// alongside an explicit edge describing the same fact.
  Map<RelationshipGroup, List<PersonRelationshipView>> groupedNeighbors(
      String personId) {
    final result = <RelationshipGroup, List<PersonRelationshipView>>{
      for (final group in RelationshipGroup.values) group: [],
    };
    final seen = <String>{};

    for (final edge in _edgesOf(personId)) {
      final neighborId = edge.otherPersonId(personId);
      if (neighborId == personId) continue; // defensive: never show a self-relationship
      final kind = edge.kindFrom(personId); // personId's own role, e.g. "parent"
      final dedupeKey = '$neighborId|${kind.raw}';
      if (!seen.add(dedupeKey)) continue;

      // Bucketed by the neighbour's own role (kind's inverse), see PersonRelationshipView.
      result[groupForKind(kind.inverse)]!.add(PersonRelationshipView(
        edgeId: edge.id,
        neighborId: neighborId,
        kind: kind,
        isDerived: edge.isDerived,
        description: edge.description,
        startDate: edge.startDate,
        endDate: edge.endDate,
        originEventId: edge.originEventId,
      ));
    }
    return result;
  }

  /// Breadth-first traversal from [startPersonId] over all edge types (including
  /// derived siblings), up to [depth] hops and [nodeLimit] persons. Returns an empty,
  /// non-truncated traversal if [startPersonId] is not in the graph. See
  /// [GraphTraversal] for what "truncated" means.
  GraphTraversal traverse(
    String startPersonId, {
    int depth = 3,
    int nodeLimit = 300,
  }) {
    if (!containsPerson(startPersonId)) {
      return const GraphTraversal(personIds: [], edges: [], truncated: false);
    }
    final clampedDepth = depth.clamp(0, 10);
    final clampedLimit = nodeLimit < 1 ? 1 : nodeLimit;

    final visited = <String>{startPersonId};
    final order = <String>[startPersonId];
    final edgesById = <String, GraphEdge>{};
    var truncated = false;

    final queue = Queue<(String, int)>()..add((startPersonId, 0));
    while (queue.isNotEmpty) {
      final (currentId, currentDepth) = queue.removeFirst();
      if (currentDepth >= clampedDepth) continue;

      for (final edge in _edgesOf(currentId)) {
        final neighborId = edge.otherPersonId(currentId);
        if (neighborId == currentId) continue;

        bool neighborIncluded;
        if (visited.contains(neighborId)) {
          neighborIncluded = true;
        } else if (visited.length < clampedLimit) {
          visited.add(neighborId);
          order.add(neighborId);
          queue.add((neighborId, currentDepth + 1));
          neighborIncluded = true;
        } else {
          neighborIncluded = false;
          truncated = true;
        }

        if (neighborIncluded) {
          edgesById[edge.id] = edge;
        }
      }
    }

    return GraphTraversal(
      personIds: order,
      edges: edgesById.values.toList(),
      truncated: truncated,
    );
  }

  /// The shortest chain of edges from [fromPersonId] to [toPersonId] (breadth-first, so
  /// shortest in hop count), or `null` if either person is not in the graph, they are
  /// the same person, or no path connects them.
  RelationshipPath? shortestPath(String fromPersonId, String toPersonId) {
    if (fromPersonId == toPersonId) return null;
    if (!containsPerson(fromPersonId) || !containsPerson(toPersonId)) return null;

    final cameFrom = <String, GraphEdge>{};
    final visited = <String>{fromPersonId};
    final queue = Queue<String>()..add(fromPersonId);

    while (queue.isNotEmpty) {
      final currentId = queue.removeFirst();
      if (currentId == toPersonId) break;
      for (final edge in _edgesOf(currentId)) {
        final neighborId = edge.otherPersonId(currentId);
        if (neighborId == currentId || !visited.add(neighborId)) continue;
        cameFrom[neighborId] = edge;
        queue.add(neighborId);
      }
    }

    if (!visited.contains(toPersonId)) return null;

    final pathPersonIds = <String>[toPersonId];
    final pathEdges = <GraphEdge>[];
    var cursor = toPersonId;
    while (cursor != fromPersonId) {
      final edge = cameFrom[cursor]!;
      pathEdges.add(edge);
      cursor = edge.otherPersonId(cursor);
      pathPersonIds.add(cursor);
    }
    final orderedPersonIds = pathPersonIds.reversed.toList();
    final orderedEdges = pathEdges.reversed.toList();

    final fragments = <String>[];
    for (var i = 0; i < orderedEdges.length; i++) {
      final edge = orderedEdges[i];
      final sourceId = orderedPersonIds[i];
      final targetId = orderedPersonIds[i + 1];
      final kind = edge.kindFrom(sourceId);
      final sourceName = personById(sourceId)?.name ?? sourceId;
      final targetName = personById(targetId)?.name ?? targetId;
      fragments.add(kind.isKnown
          ? RelationshipText.sentenceFragment(sourceName, targetName, kind.known!)
          : RelationshipText.sentenceFragmentForRaw(sourceName, targetName, kind.raw));
    }

    return RelationshipPath(
      personIds: orderedPersonIds,
      edges: orderedEdges,
      description: '${fragments.join(', ')}.',
    );
  }
}
