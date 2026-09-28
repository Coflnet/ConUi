import '../l10n/gen/app_localizations.dart';
import 'family_graph.dart';
import 'graph_layout.dart';
import 'relationship_type.dart';

/// Localized display text for the relationship logic in this package.
/// Deliberately the only place in `lib/relationships` that contains
/// user-facing strings: `relationship_type.dart`, `family_graph.dart` and
/// `graph_layout.dart` return only typed values, so this is the only file
/// that needs an [AppLocalizations] instance - every method here takes one
/// as its first parameter instead of a `BuildContext`, so it can be called
/// from a widget's `build()` (via `AppLocalizations.of(context)`) without
/// this package itself depending on Flutter's widget tree.
///
/// German relationship terms are written to be correct without knowing a
/// person's gender (e.g. "Elternteil von", "Patin oder Pate von",
/// "verheiratet mit") - see app_de.arb's `relRoleOf*`/`relSentence*` keys.
/// Each is one whole template per type per language (never built by
/// gluing a lowercased label onto a language-specific "of"/"von"), except
/// for [labelForRaw]/[roleOfLabelForRaw]/[sentenceFragmentForRaw]: those
/// exist only to describe legacy free-text connection data (in practice
/// just the old "family" value - see `relationship_type.dart`), which has
/// no per-type translation to look up, so a single generic connective
/// template is the only option there.
class RelationshipText {
  const RelationshipText._();

  /// Short display label for a known type, e.g. for a dropdown item or a group header.
  static String label(AppLocalizations l10n, RelationshipType type) {
    switch (type) {
      case RelationshipType.parent:
        return l10n.relLabelParent;
      case RelationshipType.child:
        return l10n.relLabelChild;
      case RelationshipType.grandparent:
        return l10n.relLabelGrandparent;
      case RelationshipType.grandchild:
        return l10n.relLabelGrandchild;
      case RelationshipType.stepParent:
        return l10n.relLabelStepParent;
      case RelationshipType.stepChild:
        return l10n.relLabelStepChild;
      case RelationshipType.adoptiveParent:
        return l10n.relLabelAdoptiveParent;
      case RelationshipType.adoptedChild:
        return l10n.relLabelAdoptedChild;
      case RelationshipType.godparent:
        return l10n.relLabelGodparent;
      case RelationshipType.godchild:
        return l10n.relLabelGodchild;
      case RelationshipType.guardian:
        return l10n.relLabelGuardian;
      case RelationshipType.ward:
        return l10n.relLabelWard;
      case RelationshipType.mentor:
        return l10n.relLabelMentor;
      case RelationshipType.mentee:
        return l10n.relLabelMentee;
      case RelationshipType.spouse:
        return l10n.relLabelSpouse;
      case RelationshipType.partner:
        return l10n.relLabelPartner;
      case RelationshipType.exPartner:
        return l10n.relLabelExPartner;
      case RelationshipType.sibling:
        return l10n.relLabelSibling;
      case RelationshipType.halfSibling:
        return l10n.relLabelHalfSibling;
      case RelationshipType.friend:
        return l10n.relLabelFriend;
      case RelationshipType.colleague:
        return l10n.relLabelColleague;
      case RelationshipType.neighbour:
        return l10n.relLabelNeighbour;
      case RelationshipType.acquaintance:
        return l10n.relLabelAcquaintance;
      case RelationshipType.otherRelative:
        return l10n.relLabelOtherRelative;
      case RelationshipType.other:
        return l10n.relLabelOther;
    }
  }

  /// Label for a raw stored string that may or may not be part of the known
  /// vocabulary (see [RelationshipKind]): the known [label] when recognised, otherwise
  /// the raw value itself with its first letter capitalised (e.g. the legacy `family`
  /// value reads as "Family" regardless of language - it is whatever English word an
  /// old app version happened to store, not something with a German translation on
  /// file).
  static String labelForRaw(AppLocalizations l10n, String raw) {
    final type = RelationshipType.tryParse(raw);
    if (type != null) return label(l10n, type);
    if (raw.isEmpty) return raw;
    return raw[0].toUpperCase() + raw.substring(1);
  }

  /// "&lt;Label&gt; of &lt;otherName&gt;" (e.g. "Parent of Bert") for a connection-list entry: the
  /// queried person's own role ([type]), applied to the other person named in the
  /// entry. See `FamilyGraph.groupedNeighbors`/`PersonRelationshipView` for how the
  /// role and the neighbour it is paired with here are derived.
  static String roleOfLabel(AppLocalizations l10n, RelationshipType type, String otherName) {
    switch (type) {
      case RelationshipType.parent:
        return l10n.relRoleOfParent(otherName);
      case RelationshipType.child:
        return l10n.relRoleOfChild(otherName);
      case RelationshipType.grandparent:
        return l10n.relRoleOfGrandparent(otherName);
      case RelationshipType.grandchild:
        return l10n.relRoleOfGrandchild(otherName);
      case RelationshipType.stepParent:
        return l10n.relRoleOfStepParent(otherName);
      case RelationshipType.stepChild:
        return l10n.relRoleOfStepChild(otherName);
      case RelationshipType.adoptiveParent:
        return l10n.relRoleOfAdoptiveParent(otherName);
      case RelationshipType.adoptedChild:
        return l10n.relRoleOfAdoptedChild(otherName);
      case RelationshipType.godparent:
        return l10n.relRoleOfGodparent(otherName);
      case RelationshipType.godchild:
        return l10n.relRoleOfGodchild(otherName);
      case RelationshipType.guardian:
        return l10n.relRoleOfGuardian(otherName);
      case RelationshipType.ward:
        return l10n.relRoleOfWard(otherName);
      case RelationshipType.mentor:
        return l10n.relRoleOfMentor(otherName);
      case RelationshipType.mentee:
        return l10n.relRoleOfMentee(otherName);
      case RelationshipType.spouse:
        return l10n.relRoleOfSpouse(otherName);
      case RelationshipType.partner:
        return l10n.relRoleOfPartner(otherName);
      case RelationshipType.exPartner:
        return l10n.relRoleOfExPartner(otherName);
      case RelationshipType.sibling:
        return l10n.relRoleOfSibling(otherName);
      case RelationshipType.halfSibling:
        return l10n.relRoleOfHalfSibling(otherName);
      case RelationshipType.friend:
        return l10n.relRoleOfFriend(otherName);
      case RelationshipType.colleague:
        return l10n.relRoleOfColleague(otherName);
      case RelationshipType.neighbour:
        return l10n.relRoleOfNeighbour(otherName);
      case RelationshipType.acquaintance:
        return l10n.relRoleOfAcquaintance(otherName);
      case RelationshipType.otherRelative:
        return l10n.relRoleOfOtherRelative(otherName);
      case RelationshipType.other:
        return l10n.relRoleOfOther(otherName);
    }
  }

  /// [roleOfLabel] for a possibly-unknown/legacy raw type string. See the class doc
  /// comment for why this - unlike every other method here - falls back to one
  /// generic connective template instead of a per-type one.
  static String roleOfLabelForRaw(AppLocalizations l10n, String raw, String otherName) {
    final type = RelationshipType.tryParse(raw);
    if (type != null) return roleOfLabel(l10n, type, otherName);
    return l10n.relRoleOfRawTemplate(labelForRaw(l10n, raw), otherName);
  }

  /// Full sentence describing a connection, in the app's one reading rule: "person1 is
  /// the &lt;type&gt; of person2.", e.g. `sentence(l10n, 'Anna', 'Bert', RelationshipType.parent)`
  /// -> "Anna is the parent of Bert." Used as the add/edit-connection dialog's live
  /// preview.
  static String sentence(
      AppLocalizations l10n, String person1Name, String person2Name, RelationshipType type) {
    return '${sentenceFragment(l10n, person1Name, person2Name, type)}.';
  }

  /// Same as [sentence] but for a possibly-unknown/legacy raw type string (see
  /// [labelForRaw]) - used when displaying an existing connection whose stored value
  /// predates the typed vocabulary.
  static String sentenceForRaw(
      AppLocalizations l10n, String person1Name, String person2Name, String raw) {
    return '${sentenceFragmentForRaw(l10n, person1Name, person2Name, raw)}.';
  }

  /// [sentence] without the trailing period, for chaining several hops into one
  /// shortest-path narrative, e.g. "Anna is the parent of Bert, Bert is the spouse of
  /// Clara." (see [pathDescription]).
  static String sentenceFragment(
      AppLocalizations l10n, String person1Name, String person2Name, RelationshipType type) {
    switch (type) {
      case RelationshipType.parent:
        return l10n.relSentenceParent(person1Name, person2Name);
      case RelationshipType.child:
        return l10n.relSentenceChild(person1Name, person2Name);
      case RelationshipType.grandparent:
        return l10n.relSentenceGrandparent(person1Name, person2Name);
      case RelationshipType.grandchild:
        return l10n.relSentenceGrandchild(person1Name, person2Name);
      case RelationshipType.stepParent:
        return l10n.relSentenceStepParent(person1Name, person2Name);
      case RelationshipType.stepChild:
        return l10n.relSentenceStepChild(person1Name, person2Name);
      case RelationshipType.adoptiveParent:
        return l10n.relSentenceAdoptiveParent(person1Name, person2Name);
      case RelationshipType.adoptedChild:
        return l10n.relSentenceAdoptedChild(person1Name, person2Name);
      case RelationshipType.godparent:
        return l10n.relSentenceGodparent(person1Name, person2Name);
      case RelationshipType.godchild:
        return l10n.relSentenceGodchild(person1Name, person2Name);
      case RelationshipType.guardian:
        return l10n.relSentenceGuardian(person1Name, person2Name);
      case RelationshipType.ward:
        return l10n.relSentenceWard(person1Name, person2Name);
      case RelationshipType.mentor:
        return l10n.relSentenceMentor(person1Name, person2Name);
      case RelationshipType.mentee:
        return l10n.relSentenceMentee(person1Name, person2Name);
      case RelationshipType.spouse:
        return l10n.relSentenceSpouse(person1Name, person2Name);
      case RelationshipType.partner:
        return l10n.relSentencePartner(person1Name, person2Name);
      case RelationshipType.exPartner:
        return l10n.relSentenceExPartner(person1Name, person2Name);
      case RelationshipType.sibling:
        return l10n.relSentenceSibling(person1Name, person2Name);
      case RelationshipType.halfSibling:
        return l10n.relSentenceHalfSibling(person1Name, person2Name);
      case RelationshipType.friend:
        return l10n.relSentenceFriend(person1Name, person2Name);
      case RelationshipType.colleague:
        return l10n.relSentenceColleague(person1Name, person2Name);
      case RelationshipType.neighbour:
        return l10n.relSentenceNeighbour(person1Name, person2Name);
      case RelationshipType.acquaintance:
        return l10n.relSentenceAcquaintance(person1Name, person2Name);
      case RelationshipType.otherRelative:
        return l10n.relSentenceOtherRelative(person1Name, person2Name);
      case RelationshipType.other:
        return l10n.relSentenceOther(person1Name, person2Name);
    }
  }

  /// [sentenceFragment] for a possibly-unknown/legacy raw type string.
  static String sentenceFragmentForRaw(
      AppLocalizations l10n, String person1Name, String person2Name, String raw) {
    final type = RelationshipType.tryParse(raw);
    if (type != null) return sentenceFragment(l10n, person1Name, person2Name, type);
    return l10n.relSentenceRawTemplate(
        person1Name, labelForRaw(l10n, raw).toLowerCase(), person2Name);
  }

  /// Section header for a [RelationshipGroup] on the person-detail screen.
  static String groupLabel(AppLocalizations l10n, RelationshipGroup group) {
    switch (group) {
      case RelationshipGroup.parents:
        return l10n.relGroupParents;
      case RelationshipGroup.children:
        return l10n.relGroupChildren;
      case RelationshipGroup.grandparents:
        return l10n.relGroupGrandparents;
      case RelationshipGroup.grandchildren:
        return l10n.relGroupGrandchildren;
      case RelationshipGroup.siblings:
        return l10n.relGroupSiblings;
      case RelationshipGroup.partners:
        return l10n.relGroupPartners;
      case RelationshipGroup.otherFamily:
        return l10n.relGroupOtherFamily;
      case RelationshipGroup.friendsAndOthers:
        return l10n.relGroupFriendsAndOthers;
    }
  }

  /// One sentence describing a graph edge, for the accessible text-alternative list on
  /// the relationship graph screen - the picture is never the only way to know how two
  /// people are connected. [sourceName]/[targetName] follow
  /// [GraphLayoutEdge.sourceId]/[GraphLayoutEdge.targetId] (for a parent-child edge,
  /// source is always the generationally-earlier person).
  static String graphEdgeSentence(AppLocalizations l10n, String sourceName, String targetName,
      GraphEdgeKind kind, bool isDerived) {
    switch (kind) {
      case GraphEdgeKind.parentChild:
        return l10n.relGraphEdgeParentChild(sourceName, targetName);
      case GraphEdgeKind.partner:
        return l10n.relGraphEdgePartner(sourceName, targetName);
      case GraphEdgeKind.sibling:
        return isDerived
            ? l10n.relGraphEdgeSiblingDerived(sourceName, targetName)
            : l10n.relGraphEdgeSibling(sourceName, targetName);
      case GraphEdgeKind.other:
        return l10n.relGraphEdgeOther(sourceName, targetName);
    }
  }

  /// The human-readable narrative for a [FamilyGraph.shortestPath] result: each hop's
  /// [sentenceFragment]/[sentenceFragmentForRaw], joined with ", " and ending in a
  /// single period - e.g. "Anna is the parent of Bert, Bert is the spouse of Clara."
  /// Lives here (not on `FamilyGraph`/`RelationshipPath` themselves) so the pure,
  /// Flutter-free traversal logic in `family_graph.dart` never has to import an
  /// [AppLocalizations].
  static String pathDescription(AppLocalizations l10n, FamilyGraph graph, RelationshipPath path) {
    final fragments = <String>[];
    for (var i = 0; i < path.edges.length; i++) {
      final edge = path.edges[i];
      final sourceId = path.personIds[i];
      final targetId = path.personIds[i + 1];
      final kind = edge.kindFrom(sourceId);
      final sourceName = graph.personById(sourceId)?.name ?? sourceId;
      final targetName = graph.personById(targetId)?.name ?? targetId;
      fragments.add(kind.isKnown
          ? sentenceFragment(l10n, sourceName, targetName, kind.known!)
          : sentenceFragmentForRaw(l10n, sourceName, targetName, kind.raw));
    }
    return '${fragments.join(', ')}.';
  }
}
