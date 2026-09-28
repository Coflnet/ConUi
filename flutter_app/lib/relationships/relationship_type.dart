/// Relationship semantics: a typed vocabulary of relationship types with an explicit
/// direction, plus backwards compatibility with the free-text values the app stored
/// before this vocabulary existed.
///
/// Reading rule, kept everywhere in this package and in code that consumes it: for a
/// `Connection` with `person1Id`/`person2Id`, the stored `relationshipType` is always
/// read as **"person1 is the &lt;type&gt; of person2"**.
///
/// This file is pure Dart (no Flutter imports) so it can be unit tested without the
/// widget test harness and reused from any screen. It intentionally returns only typed
/// values (enums, small records) - never user-facing strings - so a later localisation
/// pass only has to touch the text layer (see `relationship_text.dart`), not this logic.
library;

/// The known relationship vocabulary. Every directed relationship (one person is the
/// named thing *of* the other) has two members, one per direction (e.g. [parent] /
/// [child]); [inverseOf] maps between them. Every symmetric relationship (true equally
/// in both directions) has a single member and is its own inverse.
enum RelationshipType {
  // Directed: person1 is the <type> of person2.
  parent,
  child,
  grandparent,
  grandchild,
  stepParent,
  stepChild,
  adoptiveParent,
  adoptedChild,
  godparent,
  godchild,
  guardian,
  ward,
  mentor,
  mentee,

  // Symmetric: true in both directions.
  spouse,
  partner,
  exPartner,
  sibling,
  halfSibling,
  friend,
  colleague,
  neighbour,
  acquaintance,
  otherRelative,
  other;

  /// The set of directed types; anything not in it is symmetric.
  static const Set<RelationshipType> _directed = {
    parent,
    child,
    grandparent,
    grandchild,
    stepParent,
    stepChild,
    adoptiveParent,
    adoptedChild,
    godparent,
    godchild,
    guardian,
    ward,
    mentor,
    mentee,
  };

  /// True when person1 and person2 play different roles (e.g. parent/child) - swapping
  /// them changes the type to [inverseOf] itself.
  bool get isDirected => _directed.contains(this);

  /// True when the relationship reads the same regardless of direction (e.g. spouse,
  /// sibling, friend). A symmetric type is its own inverse.
  bool get isSymmetric => !isDirected;

  /// The string this type is stored/looked up as. Equal to [name] so that the legacy
  /// values the pre-vocabulary UI wrote (`friend`, `colleague`, `partner`, `spouse`,
  /// `parent`, `child`, `sibling`, `acquaintance`, `mentor`, `other`) still parse via
  /// [tryParse] without any migration - they happen to already match a member name.
  /// The one legacy value with no matching member, `family`, is left as an unknown/raw
  /// value on purpose; see [RelationshipKind].
  String get storageValue => name;

  /// Parses a stored string back into a known type, or `null` if it is not (yet) part
  /// of the vocabulary - e.g. legacy free text such as `family`, or a value written by
  /// a future app version this build does not know about.
  static RelationshipType? tryParse(String raw) {
    for (final type in values) {
      if (type.name == raw) return type;
    }
    return null;
  }
}

/// The inverse of [type]: for a directed type, the type as seen from the other person
/// (parent -> child, grandparent -> grandchild, ...); for a symmetric type, itself.
RelationshipType inverseOf(RelationshipType type) {
  switch (type) {
    case RelationshipType.parent:
      return RelationshipType.child;
    case RelationshipType.child:
      return RelationshipType.parent;
    case RelationshipType.grandparent:
      return RelationshipType.grandchild;
    case RelationshipType.grandchild:
      return RelationshipType.grandparent;
    case RelationshipType.stepParent:
      return RelationshipType.stepChild;
    case RelationshipType.stepChild:
      return RelationshipType.stepParent;
    case RelationshipType.adoptiveParent:
      return RelationshipType.adoptedChild;
    case RelationshipType.adoptedChild:
      return RelationshipType.adoptiveParent;
    case RelationshipType.godparent:
      return RelationshipType.godchild;
    case RelationshipType.godchild:
      return RelationshipType.godparent;
    case RelationshipType.guardian:
      return RelationshipType.ward;
    case RelationshipType.ward:
      return RelationshipType.guardian;
    case RelationshipType.mentor:
      return RelationshipType.mentee;
    case RelationshipType.mentee:
      return RelationshipType.mentor;
    default:
      return type; // symmetric: its own inverse
  }
}

/// A connection's `relationshipType` string, parsed against the known vocabulary.
///
/// Backwards compatibility: a value that is not in [RelationshipType] - most notably
/// the legacy `family` value the old "Add Connection" dialog offered, and any other
/// free text - is kept exactly as stored ([raw]) and treated as symmetric. This is a
/// deliberate choice, not a gap: we never guess a direction for data that was written
/// before a direction existed, we just show the raw value and let it behave like any
/// other symmetric type (same on both persons' pages, included as its own inverse).
///
/// The stored strings `parent`/`child` from the old UI *do* match known members, but
/// their direction is equally unreliable - the old screen showed "parent" on both
/// persons' pages, so a connection someone entered back then may have the roles
/// reversed from what this reading rule now implies. We still apply the reading rule
/// (rather than silently guessing something else), and the person-detail screen's
/// connection editor lets the user flip the direction once they notice it is wrong.
class RelationshipKind {
  /// The exact string this kind was parsed from / will be stored as.
  final String raw;

  /// The known type, or `null` if [raw] is not part of the vocabulary.
  final RelationshipType? known;

  const RelationshipKind._(this.raw, this.known);

  factory RelationshipKind.parse(String raw) =>
      RelationshipKind._(raw, RelationshipType.tryParse(raw));

  factory RelationshipKind.of(RelationshipType type) =>
      RelationshipKind._(type.storageValue, type);

  bool get isKnown => known != null;

  /// Symmetric unless it is a known directed type - matches [RelationshipType.isSymmetric]
  /// for known types, and defaults unknown/legacy values to symmetric (see class doc).
  bool get isSymmetric => known?.isSymmetric ?? true;

  /// The kind as seen from the other side of the connection: [inverseOf] for a known
  /// directed type, unchanged for a symmetric or unknown type.
  RelationshipKind get inverse {
    final type = known;
    if (type == null || type.isSymmetric) return this;
    return RelationshipKind.of(inverseOf(type));
  }

  @override
  bool operator ==(Object other) => other is RelationshipKind && other.raw == raw;

  @override
  int get hashCode => raw.hashCode;

  @override
  String toString() => 'RelationshipKind($raw)';
}

/// The type of [connection] as seen from [viewerPersonId] - i.e. "[viewerPersonId] is
/// the &lt;returned type&gt; of the other person in the connection". Returns the stored
/// kind unchanged when [viewerPersonId] is `person1Id`, and its [RelationshipKind.inverse]
/// when it is `person2Id`. If [viewerPersonId] matches neither side (should not happen
/// for a connection actually touching that person), the stored kind is returned as-is.
RelationshipKind relationshipKindFrom({
  required String person1Id,
  required String person2Id,
  required String relationshipType,
  required String viewerPersonId,
}) {
  final kind = RelationshipKind.parse(relationshipType);
  if (viewerPersonId == person2Id && viewerPersonId != person1Id) {
    return kind.inverse;
  }
  return kind;
}

/// Canonical `(personA, personB, typeAsSeenFromA)` triple used to compare two
/// connections for equivalence regardless of which person was stored as person1/person2
/// - e.g. `(A, parent, B)` and `(B, child, A)` describe the same fact and canonicalize
/// to the same triple. `personA` is always the lexicographically smaller id so the
/// comparison is independent of argument order.
(String, String, String) _canonicalTriple(
    String person1Id, String person2Id, RelationshipKind kind) {
  if (person1Id.compareTo(person2Id) <= 0) {
    return (person1Id, person2Id, kind.raw);
  }
  return (person2Id, person1Id, kind.inverse.raw);
}

/// True if creating a connection `person1Id -[type]-> person2Id` would duplicate a fact
/// already present in [existing] - either the same triple stored the same way, or the
/// same fact stored from the other side (e.g. adding "A is parent of B" when "B is
/// child of A" already exists). Self-connections (`person1Id == person2Id`) are never
/// reported as duplicates of anything; callers should reject them separately.
bool isDuplicateConnection({
  required Iterable<({String person1Id, String person2Id, String relationshipType})>
      existing,
  required String person1Id,
  required String person2Id,
  required RelationshipType type,
}) {
  if (person1Id == person2Id) return false;
  final target = _canonicalTriple(person1Id, person2Id, RelationshipKind.of(type));
  for (final connection in existing) {
    if (connection.person1Id == connection.person2Id) continue;
    final candidate = _canonicalTriple(
      connection.person1Id,
      connection.person2Id,
      RelationshipKind.parse(connection.relationshipType),
    );
    if (candidate == target) return true;
  }
  return false;
}
