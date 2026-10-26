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
  'half-sibling': RelationshipType.halfSibling,
  'half-brother': RelationshipType.halfSibling,
  'half-sister': RelationshipType.halfSibling,
  'halbbruder': RelationshipType.halfSibling,
  'halbschwester': RelationshipType.halfSibling,
  'grandparent': RelationshipType.grandparent,
  'grandfather': RelationshipType.grandparent,
  'grandmother': RelationshipType.grandparent,
  'großvater': RelationshipType.grandparent,
  'großmutter': RelationshipType.grandparent,
  'opa': RelationshipType.grandparent,
  'oma': RelationshipType.grandparent,
  'grandchild': RelationshipType.grandchild,
  'grandson': RelationshipType.grandchild,
  'granddaughter': RelationshipType.grandchild,
  'enkel': RelationshipType.grandchild,
  'enkelin': RelationshipType.grandchild,
  'stepparent': RelationshipType.stepParent,
  'step-parent': RelationshipType.stepParent,
  'stepfather': RelationshipType.stepParent,
  'stepmother': RelationshipType.stepParent,
  'stiefvater': RelationshipType.stepParent,
  'stiefmutter': RelationshipType.stepParent,
  'stepchild': RelationshipType.stepChild,
  'stiefkind': RelationshipType.stepChild,
  'stepson': RelationshipType.stepChild,
  'stepdaughter': RelationshipType.stepChild,
  'stiefsohn': RelationshipType.stepChild,
  'stieftochter': RelationshipType.stepChild,
  'neighbor': RelationshipType.neighbour,
  'neighbour': RelationshipType.neighbour,
  'nachbar': RelationshipType.neighbour,
  'nachbarin': RelationshipType.neighbour,
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

/// Extracts only explicit, affirmative clauses. Relative clauses use the named
/// clause head (the owner in "brother of Ben", the subject in "Ben’s brother");
/// named appositives and reverse possessives keep their role holder, while
/// paired statements only introduce symmetric relationships. General
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
  final relation = _relationshipWords.keys.join('|');
  final namedRole = _pattern(
      '^(?:my|our|your|his|her|their|mein(?:e[nmrs]?)?|dein(?:e[nmrs]?)?|sein(?:e[nmrs]?)?|ihr(?:e[nmrs]?)?|unser(?:e[nmrs]?)?|euer|eure[nmrs]?)\\s+(?:$relation)(?:\\s+|\$)');
  final capitalized = RegExp(
      r"^(?:(?:von|van|de|der|den|zu|zur)\s+)*\p{Lu}[\p{L}\p{M}]*(?:[-'’]\p{L}[\p{L}\p{M}]*)*(?:\s+(?:(?:von|van|de|der|den|zu|zur)\s+)*\p{Lu}[\p{L}\p{M}]*(?:[-'’]\p{L}[\p{L}\p{M}]*)*){0,3}$",
      unicode: true);
  // These are pronouns or common sentence/noun slots, never unfamiliar people.
  final nonNames = _pattern(
      r'^(?:he|she|it|they|we|i|you|him|her|them|us|me|his|hers|its|ours|yours|theirs|'
      r'er|sie|es|wir|ich|du|ihn|ihm|ihr|ihnen|mir|mich|dir|dich|uns|euch|der|die|das|'
      r'auto|car|garten|garden|stadt|city|firma|company|museum|weihnachten|'
      r'man|woman|mann|frau|jemand|someone|niemand|nobody)$');
  String? personName(String raw) {
    final name =
        raw.trim().replaceFirst(namedRole, '').replaceAll(RegExp(r'\s+'), ' ');
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

  final direct = _pattern(
      '^(.*?)\\s+(?:is|ist)\\s+(?:(?:the|a|an|der|die|ein|eine)\\s+)?($relation)\\s+(?:of|von)\\s+(.+?)(?:\\s+ist)?\$');
  const ownership = r"(?:[’']s|s|[’'])";
  final possessive = _pattern('^(.*?)\\s+(?:is|ist)\\s+'
      r'(?!(?:his|hers|its|ours|yours|theirs)\b)'
      '(.+?)$ownership\\s+($relation)\$');
  final reversePossessive =
      _pattern(r'^(?!(?:his|hers|its|ours|yours|theirs)\b)'
          '(.+?)$ownership\\s+($relation)\\s+(?:is|ist)\\s+(.+)\$');
  final appositive = _pattern(
      '^(.+?),\\s*((?:(?:the|a|an|der|die|ein|eine)\\s+)?(?:$relation)\\s+(?:of|von)\\s+[^,]+|[^,]+$ownership\\s+(?:$relation))(?=,|\$)');
  const pairedWords = {
    'siblings': 'brother',
    'brothers': 'brother',
    'sisters': 'sister',
    'geschwister': 'bruder',
    'brüder': 'bruder',
    'schwestern': 'schwester',
    'friends': 'friend',
    'freunde': 'freund',
    'freundinnen': 'freundin',
    'colleagues': 'colleague',
    'kollegen': 'kollege',
    'kolleginnen': 'kollegin',
    'partners': 'partner',
    'partner': 'partner',
    'partnerinnen': 'partnerin',
    'spouses': 'spouse',
    'married': 'spouse',
    'verheiratet': 'spouse',
    'neighbors': 'neighbor',
    'neighbours': 'neighbour',
    'nachbarn': 'nachbar',
    'nachbarinnen': 'nachbarin',
    'half-siblings': 'half-brother',
    'halbgeschwister': 'halbbruder',
  };
  final paired = _pattern(
      '^(.*?)\\s+(?:and|und)\\s+(.+?)\\s+(?:are|sind)\\s+(${pairedWords.keys.join('|')})\$');
  final married = _pattern(
      r'^(.*?)\s+(?:is\s+married\s+to\s+(.+)|ist\s+mit\s+(.+)\s+verheiratet)$');
  final employer = _pattern(
      r'^(.*?)\s+(?:(?:works?\s+(?:at|for)|arbeitet\s+bei)\s+(.+)|bei\s+(.+)\s+arbeitet)$');
  final car = _pattern(
      r'^(.*?)\s+(?:(?:got|bought|has)\s+a\s+new\s+car|(?:hat|kaufte)\s+ein\s+neues\s+Auto)$');
  final residence = _pattern(
      r'^(.*?)\s+(?:(?:lives\s+(?:at|in)|wohnt\s+in)\s+\S.*|in\s+\S.*\s+wohnt)$');
  final uncertain = _pattern(
      r'\b(?:not|never|no|nicht|kein\w*|nie|maybe|perhaps|vielleicht|'
      r'possibly|probably|angeblich|wohl|vermutlich|might|may|could|would|'
      r'allegedly|supposedly|apparently|reportedly|anscheinend|scheinbar|'
      r'should|can|must|könnte|kann|würde|soll\w*|muss|if|wenn|falls|'
      r'said|says|heard|thinks?|believes?|sagt\w*|sagte|glaub\w*|denkt|behaupt\w*)\b');
  for (final sentenceMatch in RegExp(r'[^.!?\n]+[.!?]?').allMatches(text)) {
    final sentence = sentenceMatch.group(0)!.trim();
    if (sentence.endsWith('?') || uncertain.hasMatch(sentence)) continue;
    var body = sentence.replaceFirst(RegExp(r'[.!]$'), '');
    final clauses = <(String, String, bool)>[];
    final pair = paired.firstMatch(body);
    final apposition = appositive.firstMatch(body);
    if (pair != null &&
        !_pattern(r'\b(?:and|und)\b').hasMatch(pair.group(2)!)) {
      clauses.add((
        '${pair.group(1)} is ${pairedWords[pair.group(3)!.toLowerCase()]} of ${pair.group(2)}',
        body,
        false
      ));
      body = '';
    } else if (apposition != null && personName(apposition.group(1)!) != null) {
      clauses.add((
        '${apposition.group(1)} is ${apposition.group(2)}',
        apposition.group(0)!,
        true
      ));
      body = body.substring(apposition.end);
    }
    clauses.addAll(body
        .split(_pattern(r',\s*|\s+(?:and|und)\s+|\s+(?=(?:who|which)\s+|'
            r'(?:der|die)\s+(?:bei|arbeitet|ein|eine|in|wohnt)\b)'))
        .map((raw) => (raw.trim(), raw.trim(), false)));
    String? subject;
    String? antecedent;
    for (final (raw, source, isAppositive) in clauses) {
      if (source.isEmpty) continue;
      var clause = raw;
      final relative =
          _pattern(r'^(?:who|which|der|die)\s+').firstMatch(clause);
      if (relative != null) {
        subject = antecedent;
        clause = clause.substring(relative.end);
      }
      if (relative != null ||
          _pattern(r'^(?:is|ist|works?\s|arbeitet\s|bei\s|lives\s|wohnt\s|in\s|'
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
      final directMatch = direct.firstMatch(clause);
      var objectIsAntecedent = directMatch != null;
      var match = directMatch;
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
        } else {
          match = reversePossessive.firstMatch(clause);
          if (match != null) {
            first = personName(match.group(3)!);
            second = personName(match.group(1)!);
            word = match.group(2)!;
          } else {
            match = married.firstMatch(clause);
            if (match != null) {
              first = personName(match.group(1)!);
              second = personName((match.group(2) ?? match.group(3))!);
              word = 'spouse';
              objectIsAntecedent = true;
            }
          }
        }
      }
      if (first != null && second != null && word != null) {
        subject = first;
        antecedent = objectIsAntecedent && !isAppositive ? second : first;
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
      match = car.firstMatch(clause) ?? residence.firstMatch(clause);
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
