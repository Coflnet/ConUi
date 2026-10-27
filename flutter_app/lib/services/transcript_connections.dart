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

const _monthWords = r'(?:Januar|Februar|März|April|Mai|Juni|Juli|August|'
    r'September|Oktober|November|Dezember|January|February|March|May|'
    r'June|July|October|December)';

Iterable<String> _transcriptAssertions(String text) sync* {
  final abbreviation =
      _pattern(r'\b(?:Dr|Prof|Mr|Mrs|Ms|St|Str|Apt|Nr|No|OG|EG)\.$');
  final ordinal = _pattern(r'\b\d{1,2}\.$');
  final ordinalContinuation =
      _pattern('^(?:$_monthWords|OG|EG|Etage|Stock)\\b');
  final context = _pattern(r'\b(?:if|wenn|falls|said|says|heard|sagt\w*|'
      r'glaub\w*|thinks?|believes?|denkt|behaupt\w*)\b');
  var start = 0;
  for (final boundary
      in RegExp(r'[!?]\s*|\.(?:\s+|(?=\p{Lu})|$)|\n+|$', unicode: true)
          .allMatches(text)) {
    if (boundary.start < text.length && text[boundary.start] == '.') {
      final head = text.substring(start, boundary.start + 1);
      final tail = text.substring(boundary.end);
      if (tail.isNotEmpty &&
          (abbreviation.hasMatch(head) ||
              (ordinal.hasMatch(head) && ordinalContinuation.hasMatch(tail)))) {
        continue;
      }
    }
    final sentence = text.substring(start, boundary.end).trim();
    start = boundary.end;
    if (sentence.isEmpty) continue;
    // Contrast can introduce an independent assertion, but cannot release a
    // question, conditional, or reported claim from its original scope.
    yield* sentence.endsWith('?') || context.hasMatch(sentence)
        ? [sentence]
        : sentence
            .split(_pattern(r',(?=\s*(?:aber|but)\b)'))
            .map((s) => s.trim());
  }
}

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
  final residence =
      _pattern(r'^(.*?)\s+(?:(?:(?:lives|lived|used\s+to\s+live)\s+(?:at|in)|'
          r'(?:wohnt|wohnte)(?:\s+früher)?\s+in)\s+\S.*|'
          r'in\s+\S.*\s+(?:wohnt|wohnte)|'
          r'(?:ist\s+nach\s+\S.*\s+gezogen|'
          r'zieht(?:\s+\S+){0,4}\s+nach\s+\S.*|'
          r'(?:moved|is\s+moving|will\s+move)\s+to\s+\S.*))$');
  final sharedResidence =
      _pattern(r'^(.*?)\s+(?:und|and)\s+(.+?)\s+(?:wohnen\s+(?:zusammen\s+)?in|'
          r'live\s+(?:together\s+)?(?:in|at))\s+\S.*$');
  const profession = r'(?:Zahnärztin|Zahnarzt|Ärztin|Arzt|Lehrer(?:in)?|'
      r'Ingenieur(?:in)?|Entwickler(?:in)?|Programmierer(?:in)?|'
      r'Krankenpfleger(?:in)?|Krankenschwester|Architekt(?:in)?|'
      r'Anwältin|Anwalt|Koch|Köchin|Erzieher(?:in)?|'
      r'dentist|doctor|teacher|engineer|developer|programmer|nurse|'
      r'architect|lawyer|chef)';
  const date = '(?:\\d{1,2}\\.?\\s+$_monthWords\\s+\\d{4}|'
      '$_monthWords\\s+\\d{1,2},?\\s+\\d{4}|\\d{1,2}\\.\\d{1,2}\\.\\d{4})';
  final personalFact = _pattern('^(.*?)\\s+(?:'
      '(?:is|ist)\\s+(?:(?:a|an|ein|eine)\\s+)?$profession|'
      '(?:(?:ein|eine)\\s+)?$profession\\s+ist|'
      r'(?:spielt|plays|enjoys)\s+\S.*|'
      r'(?:hat\s+(?:einen|eine|ein)|(?:has|owns)\s+a)\s+'
      r'(?:Hund|Katze|Vogel|Kaninchen|Pferd|dog|cat|bird|rabbit|horse)'
      r'(?:\s+(?:namens|named|called)\s+\S.*)?|'
      'hat\\s+am\\s+$date\\s+Geburtstag|'
      'was\\s+born\\s+on\\s+$date|wurde\\s+am\\s+$date\\s+geboren|'
      r'(?:hat\s+die\s+Telefonnummer|has\s+(?:the\s+)?phone\s+number)\s+'
      r'\+?\d[\d ()/-]{4,}\d)$');
  final uncertain = _pattern(
      r'\b(?:not|never|no|nicht|kein\w*|nie|maybe|perhaps|vielleicht|'
      r'possibly|probably|angeblich|wohl|vermutlich|might|could|would|'
      r'may(?=\s+(?:be|live|work|have|move|own|play|enjoy)\b)|'
      r'allegedly|supposedly|apparently|reportedly|anscheinend|scheinbar|'
      r'eventuell|möglicherweise|voraussichtlich|potentially|oder|or|nein|'
      r'should|can|must|könnte|kann|würde|soll\w*|muss|if|wenn|falls|'
      r'said|says|heard|thinks?|believes?|sagt\w*|sagte|glaub\w*|denkt|behaupt\w*)\b');
  const finitePredicate = r'(?:is|ist|works?|arbeitet|lives|lived|wohnt|wohnte|'
      r'used\s+to\s+live|moved|will\s+move|zieht|hat|has|owns|plays|spielt|enjoys|'
      r'was|wurde)\b';
  const predicate = '(?:$finitePredicate|(?:bei|in)\\b)';
  final explicitStart = _pattern('^(.+?)\\s+$finitePredicate');
  final implicitStart = _pattern('^(?:$finitePredicate|bei\\s+|'
      'in\\s+.+\\s+(?:wohnt|wohnte)\\b|'
      '(?:(?:the|a|an|der|die|ein|eine)\\s+)?(?:$relation)\\s+(?:of|von)\\s+)');
  final relativeStart = _pattern(r'^(?:who|which|der|die)\s+');
  final clauseSeparator = _pattern(r',\s*|\s+(?:and|und)\s+|'
      '\\s+(?=(?:who|which)\\s+|(?:der|die)\\s+'
      '(?:$predicate|(?:ein|eine)\\b|$profession\\b))');
  final correction =
      _pattern(r'^(.*?)\s+(wohnt\s+in|lives\s+(?:in|at))\s+[^,]+,\s*'
          r'(?:nein|no|sorry|ich\s+meine|I\s+mean),?\s+(?:in|at)\s+([^,]+)$');
  for (final sentence in _transcriptAssertions(text)) {
    if (sentence.endsWith('?')) continue;
    var body = sentence.replaceFirst(RegExp(r'[.!]$'), '');
    final corrected = correction.firstMatch(body);
    final original = body;
    if (corrected != null) {
      body =
          '${corrected.group(1)} ${corrected.group(2)} ${corrected.group(3)}';
    }
    if (uncertain.hasMatch(body)) continue;
    final clauses = <(String, String, bool)>[];
    final pair = paired.firstMatch(body);
    final apposition = appositive.firstMatch(body);
    if (corrected != null) {
      clauses.add((body, original, false));
      body = '';
    } else if (pair != null &&
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
    var start = 0;
    for (final separator in clauseSeparator.allMatches(body)) {
      final tail = body.substring(separator.end);
      final explicit = explicitStart.firstMatch(tail);
      if (relativeStart.hasMatch(tail) ||
          implicitStart.hasMatch(tail) ||
          (explicit != null && personName(explicit.group(1)!) != null)) {
        final raw = body.substring(start, separator.start).trim();
        clauses.add((raw, raw, false));
        start = separator.end;
      }
    }
    final raw = body.substring(start).trim();
    clauses.add((raw, raw, false));
    String? subject;
    String? antecedent;
    for (final (raw, source, isAppositive) in clauses) {
      if (source.isEmpty) continue;
      var clause = raw.replaceFirst(_pattern(r'^(?:aber|but)\s+'), '');
      final relative =
          _pattern(r'^(?:who|which|der|die)\s+').firstMatch(clause);
      if (relative != null) {
        subject = antecedent;
        clause = clause.substring(relative.end);
      }
      if (relative != null ||
          _pattern('^(?:$predicate|(?:the|a|an|der|die|ein|eine)\\s+)')
              .hasMatch(clause)) {
        if (subject == null) continue;
        // A coordinated role can omit its copula; German relatives put it last.
        if (_pattern(
                '^(?:(?:the|a|an|der|die|ein|eine)\\s+)?($relation)\\s+(?:of|von)\\s+')
            .hasMatch(clause)) {
          clause = 'is ${clause.replaceFirst(_pattern(r'\s+ist$'), '')}';
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
      match = sharedResidence.firstMatch(clause);
      if (match != null) {
        final names = [
          personName(match.group(1)!),
          personName(match.group(2)!)
        ];
        if (names.every((name) => name != null)) {
          for (final name in names) {
            fact(name!, clause, source);
          }
          // A plural subject cannot license a subsequent singular predicate.
          subject = antecedent = null;
          continue;
        }
      }
      match = car.firstMatch(clause) ??
          residence.firstMatch(clause) ??
          personalFact.firstMatch(clause);
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
