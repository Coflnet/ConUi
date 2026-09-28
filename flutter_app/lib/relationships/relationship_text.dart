import 'family_graph.dart';
import 'graph_layout.dart';
import 'relationship_type.dart';

/// English display text for the relationship logic in this package. Deliberately the
/// only place in `lib/relationships` that contains user-facing strings: `relationship_type.dart`,
/// `family_graph.dart` and `graph_layout.dart` return only typed values, so a later
/// localisation pass only has to replace this class (and its sibling text classes added
/// alongside later steps), never the logic that computes what to say.
class RelationshipText {
  const RelationshipText._();

  /// Short display label for a known type, e.g. for a dropdown item or a group header.
  static String label(RelationshipType type) {
    switch (type) {
      case RelationshipType.parent:
        return 'Parent';
      case RelationshipType.child:
        return 'Child';
      case RelationshipType.grandparent:
        return 'Grandparent';
      case RelationshipType.grandchild:
        return 'Grandchild';
      case RelationshipType.stepParent:
        return 'Step-parent';
      case RelationshipType.stepChild:
        return 'Step-child';
      case RelationshipType.adoptiveParent:
        return 'Adoptive parent';
      case RelationshipType.adoptedChild:
        return 'Adopted child';
      case RelationshipType.godparent:
        return 'Godparent';
      case RelationshipType.godchild:
        return 'Godchild';
      case RelationshipType.guardian:
        return 'Guardian';
      case RelationshipType.ward:
        return 'Ward';
      case RelationshipType.mentor:
        return 'Mentor';
      case RelationshipType.mentee:
        return 'Mentee';
      case RelationshipType.spouse:
        return 'Spouse';
      case RelationshipType.partner:
        return 'Partner';
      case RelationshipType.exPartner:
        return 'Ex-partner';
      case RelationshipType.sibling:
        return 'Sibling';
      case RelationshipType.halfSibling:
        return 'Half-sibling';
      case RelationshipType.friend:
        return 'Friend';
      case RelationshipType.colleague:
        return 'Colleague';
      case RelationshipType.neighbour:
        return 'Neighbour';
      case RelationshipType.acquaintance:
        return 'Acquaintance';
      case RelationshipType.otherRelative:
        return 'Other relative';
      case RelationshipType.other:
        return 'Other';
    }
  }

  /// Label for a raw stored string that may or may not be part of the known
  /// vocabulary (see [RelationshipKind]): the known [label] when recognised, otherwise
  /// the raw value itself with its first letter capitalised (e.g. the legacy `family`
  /// value reads as "Family").
  static String labelForRaw(String raw) {
    final type = RelationshipType.tryParse(raw);
    if (type != null) return label(type);
    if (raw.isEmpty) return raw;
    return raw[0].toUpperCase() + raw.substring(1);
  }

  /// "&lt;Label&gt; of &lt;otherName&gt;" (e.g. "Parent of Bert") for a connection-list entry: the
  /// queried person's own role ([type]), applied to the other person named in the
  /// entry. See `FamilyGraph.groupedNeighbors`/`PersonRelationshipView` for how the
  /// role and the neighbour it is paired with here are derived.
  static String roleOfLabel(RelationshipType type, String otherName) =>
      '${label(type)} of $otherName';

  /// [roleOfLabel] for a possibly-unknown/legacy raw type string.
  static String roleOfLabelForRaw(String raw, String otherName) =>
      '${labelForRaw(raw)} of $otherName';

  /// Full sentence describing a connection, in the app's one reading rule: "person1 is
  /// the &lt;type&gt; of person2.", e.g. `sentence('Anna', 'Bert', RelationshipType.parent)`
  /// -> "Anna is the parent of Bert." Used as the add/edit-connection dialog's live
  /// preview.
  static String sentence(String person1Name, String person2Name, RelationshipType type) {
    return '${sentenceFragment(person1Name, person2Name, type)}.';
  }

  /// Same as [sentence] but for a possibly-unknown/legacy raw type string (see
  /// [labelForRaw]) - used when displaying an existing connection whose stored value
  /// predates the typed vocabulary.
  static String sentenceForRaw(String person1Name, String person2Name, String raw) {
    return '${sentenceFragmentForRaw(person1Name, person2Name, raw)}.';
  }

  /// [sentence] without the trailing period, for chaining several hops into one
  /// shortest-path narrative, e.g. "Anna is the parent of Bert, Bert is the spouse of
  /// Clara." (see `FamilyGraph.shortestPath`).
  static String sentenceFragment(String person1Name, String person2Name, RelationshipType type) {
    return '$person1Name is the ${label(type).toLowerCase()} of $person2Name';
  }

  /// [sentenceFragment] for a possibly-unknown/legacy raw type string.
  static String sentenceFragmentForRaw(String person1Name, String person2Name, String raw) {
    return '$person1Name is the ${labelForRaw(raw).toLowerCase()} of $person2Name';
  }

  /// Section header for a [RelationshipGroup] on the person-detail screen.
  static String groupLabel(RelationshipGroup group) {
    switch (group) {
      case RelationshipGroup.parents:
        return 'Parents';
      case RelationshipGroup.children:
        return 'Children';
      case RelationshipGroup.grandparents:
        return 'Grandparents';
      case RelationshipGroup.grandchildren:
        return 'Grandchildren';
      case RelationshipGroup.siblings:
        return 'Siblings';
      case RelationshipGroup.partners:
        return 'Partners';
      case RelationshipGroup.otherFamily:
        return 'Other family';
      case RelationshipGroup.friendsAndOthers:
        return 'Friends & others';
    }
  }

  /// One sentence describing a graph edge, for the accessible text-alternative list on
  /// the relationship graph screen - the picture is never the only way to know how two
  /// people are connected. [sourceName]/[targetName] follow
  /// [GraphLayoutEdge.sourceId]/[GraphLayoutEdge.targetId] (for a parent-child edge,
  /// source is always the generationally-earlier person).
  static String graphEdgeSentence(
      String sourceName, String targetName, GraphEdgeKind kind, bool isDerived) {
    switch (kind) {
      case GraphEdgeKind.parentChild:
        return '$sourceName is the parent of $targetName.';
      case GraphEdgeKind.partner:
        return '$sourceName and $targetName are partners.';
      case GraphEdgeKind.sibling:
        return isDerived
            ? '$sourceName and $targetName are siblings (derived from shared parents).'
            : '$sourceName and $targetName are siblings.';
      case GraphEdgeKind.other:
        return '$sourceName is connected to $targetName.';
    }
  }
}
