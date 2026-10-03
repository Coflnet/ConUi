import '../models/person.dart';
import '../relationships/relationship_type.dart';
import 'person_mentions.dart';

class TranscriptConnection {
  final String person1Name;
  final String person2Name;
  final RelationshipType type;
  final String sourceText;

  const TranscriptConnection(
      {required this.person1Name,
      required this.person2Name,
      required this.type,
      required this.sourceText});
}

class TranscriptPersonFact {
  final String personName;
  final String value;
  final String sourceText;
  final bool isCompany;

  const TranscriptPersonFact(
      {required this.personName,
      required this.value,
      required this.sourceText,
      this.isCompany = false});
}

class TranscriptConnections {
  final List<TranscriptConnection> connections;
  final List<TranscriptPersonFact> facts;

  const TranscriptConnections({required this.connections, required this.facts});
}

const _relationshipWords = {
  'brother': RelationshipType.sibling,
  'sister': RelationshipType.sibling,
  'bruder': RelationshipType.sibling,
  'schwester': RelationshipType.sibling,
  'father': RelationshipType.parent,
  'mother': RelationshipType.parent,
  'vater': RelationshipType.parent,
  'mutter': RelationshipType.parent,
  'son': RelationshipType.child,
  'daughter': RelationshipType.child,
  'sohn': RelationshipType.child,
  'tochter': RelationshipType.child,
  'colleague': RelationshipType.colleague,
  'collegue': RelationshipType.colleague,
  'kollege': RelationshipType.colleague,
  'kollegin': RelationshipType.colleague,
  'friend': RelationshipType.friend,
  'freund': RelationshipType.friend,
  'freundin': RelationshipType.friend,
  'partner': RelationshipType.partner,
  'partnerin': RelationshipType.partner,
  'spouse': RelationshipType.spouse,
  'husband': RelationshipType.spouse,
  'wife': RelationshipType.spouse,
  'ehemann': RelationshipType.spouse,
  'ehefrau': RelationshipType.spouse,
};

RegExp _pattern(String pattern) =>
    RegExp(pattern, caseSensitive: false, unicode: true);

/// Extracts only explicit, affirmative clauses. Relative clauses use the last
/// named person; coordinated predicates keep their clause's subject. General
/// pronouns and uncertain sentences deliberately carry no inferred facts.
TranscriptConnections extractTranscriptConnections(
    String text, List<Person> people) {
  final connections = <TranscriptConnection>[];
  final facts = <TranscriptPersonFact>[];
  final known = <String>{};
  for (final person in people.where((p) => !p.isDeleted)) {
    for (final name in [person.name, ...person.aliases]) {
      known.add(normalizedPersonName(name));
    }
    known.add(normalizedPersonName(person.name).split(' ').first);
  }
  final capitalized = RegExp(
      r"^(?:(?:von|van|de|der|den|zu|zur)\s+)*\p{Lu}[\p{L}\p{M}]*(?:[-'’]\p{L}[\p{L}\p{M}]*)*(?:\s+(?:(?:von|van|de|der|den|zu|zur)\s+)*\p{Lu}[\p{L}\p{M}]*(?:[-'’]\p{L}[\p{L}\p{M}]*)*){0,3}$",
      unicode: true);
  // These are pronouns or common sentence/noun slots, never unfamiliar people.
  final nonNames =
      _pattern(r'^(?:he|she|it|they|we|i|you|er|sie|es|wir|ich|du|der|die|das|'
          r'auto|car|garten|garden|stadt|city|firma|company|museum|weihnachten|'
          r'man|woman|mann|frau|jemand|someone|niemand|nobody)$');
  String? personName(String raw) {
    final name = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (name.isEmpty ||
        nonNames.hasMatch(name) ||
        _pattern(r'^(?:das|the|ein|eine)\s+').hasMatch(name)) {
      return null;
    }
    return known.contains(normalizedPersonName(name)) ||
            capitalized.hasMatch(name)
        ? name
        : null;
  }

  String identity(String name) {
    final mentions = extractPersonMentions(name, people);
    if (mentions.length == 1 &&
        mentions.single.matches.length == 1 &&
        normalizedPersonName(mentions.single.name) ==
            normalizedPersonName(name)) {
      return 'id:${mentions.single.matches.single.id}';
    }
    return 'name:${normalizedPersonName(name)}';
  }

  final seenFacts = <String>{};
  void fact(String name, String value, String source, {bool company = false}) {
    if (seenFacts
        .add('${identity(name)}|$company|${normalizedPersonName(value)}')) {
      facts.add(TranscriptPersonFact(
          personName: name,
          value: value,
          sourceText: source,
          isCompany: company));
    }
  }

  final relation = _relationshipWords.keys.join('|');
  final direct = _pattern(
      '^(.*?)\\s+(?:is|ist)\\s+(?:(?:the|a|an|der|die|ein|eine)\\s+)?($relation)\\s+(?:of|von)\\s+(.+?)(?:\\s+ist)?\$');
  final possessive =
      _pattern('^(.*?)\\s+(?:is|ist)\\s+(.+?)(?:[’\']s|s)\\s+($relation)\$');
  final employer = _pattern(
      r'^(.*?)\s+(?:(?:works?\s+(?:at|for)|arbeitet\s+bei)\s+(.+)|bei\s+(.+)\s+arbeitet)$');
  final car = _pattern(
      r'^(.*?)\s+(?:(?:got|bought|has)\s+a\s+new\s+car|(?:hat|kaufte)\s+ein\s+neues\s+Auto)$');
  final uncertain = _pattern(
      r'\b(?:not|never|no|nicht|kein\w*|nie|maybe|perhaps|vielleicht|'
      r'possibly|probably|angeblich|wohl|vermutlich|might|may|could|would|'
      r'should|can|must|könnte|kann|würde|soll\w*|muss|if|wenn|falls|'
      r'said|says|heard|thinks?|believes?|sagt\w*|sagte|glaub\w*|denkt|behaupt\w*)\b');
  for (final sentenceMatch in RegExp(r'[^.!?\n]+[.!?]?').allMatches(text)) {
    final sentence = sentenceMatch.group(0)!.trim();
    if (sentence.endsWith('?') || uncertain.hasMatch(sentence)) continue;
    final body = sentence.replaceFirst(RegExp(r'[.!]$'), '');
    String? subject;
    String? antecedent;
    for (final raw
        in body.split(_pattern(r',\s*|\s+(?:and|und)\s+|\s+(?=(?:who|which)\s+|'
            r'(?:der|die)\s+(?:bei|arbeitet|ein|eine)\b)'))) {
      final source = raw.trim();
      if (source.isEmpty) continue;
      var clause = source;
      final relative =
          _pattern(r'^(?:who|which|der|die)\s+').firstMatch(clause);
      if (relative != null) {
        subject = antecedent;
        clause = clause.substring(relative.end);
      }
      if (relative != null ||
          _pattern(r'^(?:is|ist|works?\s|arbeitet\s|bei\s|'
                  r'(?:the|a|an|der|die|ein|eine)\s+)')
              .hasMatch(clause)) {
        if (subject == null) continue;
        // German relative predicates put "ist" at the end.
        if (_pattern(
                '^(?:(?:der|die|ein|eine)\\s+)?($relation)\\s+von\\s+.+\\s+ist\$')
            .hasMatch(clause)) {
          clause = 'ist ${clause.replaceFirst(_pattern(r'\s+ist$'), '')}';
        }
        clause = '$subject $clause';
      } else {
        subject = null;
        antecedent = null;
      }
      var match = direct.firstMatch(clause);
      String? first;
      String? second;
      String? word;
      if (match != null) {
        first = personName(match.group(1)!);
        word = match.group(2)!;
        second = personName(match.group(3)!);
      } else {
        match = possessive.firstMatch(clause);
        if (match != null) {
          first = personName(match.group(1)!);
          second = personName(match.group(2)!);
          word = match.group(3)!;
        }
      }
      if (first != null && second != null && word != null) {
        subject = first;
        antecedent = second;
        final type = _relationshipWords[word.toLowerCase()]!;
        final a = identity(first);
        final b = identity(second);
        if (a != b &&
            !isDuplicateConnection(
                existing: connections.map((c) => (
                      person1Id: identity(c.person1Name),
                      person2Id: identity(c.person2Name),
                      relationshipType: c.type.name
                    )),
                person1Id: a,
                person2Id: b,
                type: type)) {
          connections.add(TranscriptConnection(
              person1Name: first,
              person2Name: second,
              type: type,
              sourceText: source));
        }
        continue;
      }
      match = employer.firstMatch(clause);
      if (match != null) {
        final name = personName(match.group(1)!);
        if (name != null) {
          subject = antecedent = name;
          fact(name, (match.group(2) ?? match.group(3))!.trim(), source,
              company: true);
          continue;
        }
      }
      match = car.firstMatch(clause);
      if (match != null) {
        final name = personName(match.group(1)!);
        if (name != null) {
          subject = antecedent = name;
          fact(name, clause, source);
          continue;
        }
      }
      // An unrecognized clause cannot license a subsequent implicit subject.
      subject = antecedent = null;
    }
  }
  return TranscriptConnections(connections: connections, facts: facts);
}
