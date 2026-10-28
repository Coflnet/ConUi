import '../models/person.dart';
import '../relationships/relationship_type.dart';
import 'person_mentions.dart';
import 'transcript_relationship_vocabulary.dart';

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

RegExp _pattern(String pattern) =>
    RegExp(pattern, caseSensitive: false, unicode: true);

const _monthWords = r'(?:Januar|Februar|März|April|Mai|Juni|Juli|August|'
    r'September|Oktober|November|Dezember|January|February|March|May|'
    r'June|July|October|December)';

Iterable<String> _transcriptAssertions(
    String text, bool Function(String) independentAssertion) sync* {
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
    var assertionStart = 0;
    if (!sentence.endsWith('?') && !context.hasMatch(sentence)) {
      for (final contrast
          in _pattern(r',\s*(?:aber|but)\s+').allMatches(sentence)) {
        if (independentAssertion(sentence.substring(contrast.end))) {
          yield sentence.substring(assertionStart, contrast.start).trim();
          assertionStart = contrast.start + 1;
        }
      }
    }
    yield sentence.substring(assertionStart).trim();
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
  final relation = transcriptRelationshipPattern;
  final namedRole = _pattern(
      '^(?:my|our|your|his|her|their|mein(?:e[nmrs]?)?|dein(?:e[nmrs]?)?|sein(?:e[nmrs]?)?|ihr(?:e[nmrs]?)?|unser(?:e[nmrs]?)?|euer|eure[nmrs]?)\\s+(?:$relation)(?:\\s+|\$)');
  final capitalized = RegExp(
      r"^(?:(?:von|van|de|der|den|zu|zur)\s+)*\p{Lu}[\p{L}\p{M}]*(?:[-'’]\p{L}[\p{L}\p{M}]*)*(?:\s+(?:(?:von|van|de|der|den|zu|zur)\s+)*\p{Lu}[\p{L}\p{M}]*(?:[-'’]\p{L}[\p{L}\p{M}]*)*){0,3}$",
      unicode: true);
  // These are pronouns or common sentence/noun slots, never unfamiliar people.
  final nonNames = _pattern(
      r'^(?:he|she|it|they|we|i|you|him|her|them|us|me|his|hers|its|ours|yours|theirs|'
      r'mine|myself|yourself|himself|herself|itself|ourselves|themselves|yourselves|'
      r'er|sie|es|wir|ich|du|ihn|ihm|ihr|ihnen|mir|mich|dir|dich|uns|euch|sich|der|die|das|'
      r'auto|car|garten|garden|stadt|city|firma|company|museum|weihnachten|'
      r'man|woman|mann|frau|jemand|someone|niemand|nobody|dog|cat|hund|katze)$');
  String? personName(String raw) {
    final name = raw
        .trim()
        .replaceFirst(namedRole, '')
        .replaceFirst(_pattern(r'^(?:(?:Dr|Prof|Mr|Mrs|Ms)\.\s+)+'), '')
        .replaceAll(RegExp(r'\s+'), ' ');
    if (name.isEmpty ||
        _pattern(r'\b(?:and|und)\b').hasMatch(name) ||
        _pattern('^(?:$relation)\$').hasMatch(name) ||
        _pattern(r'\b(?:GmbH|AG|Inc|Ltd|LLC|Corp)\.?$').hasMatch(name) ||
        nonNames.hasMatch(name) ||
        _pattern(
                r'^(?:(?:the|der|die|das)\s+)?(?:company|firma|unternehmen|organisation|organization|verein)\b')
            .hasMatch(name) ||
        _pattern(
                r'^(?:(?:my|our|his|her|mein(?:e[nmrs]?)?|sein(?:e[nmrs]?)?|ihr(?:e[nmrs]?)?)\s+)?(?:Hund|Katze|Pferd|Vogel|dog|cat|horse|bird)\b')
            .hasMatch(name) ||
        _pattern(r'^(?:das|the|ein|eine)\s+').hasMatch(name)) {
      return null;
    }
    return known.contains(normalizedPersonName(name)) ||
            capitalized.hasMatch(name)
        ? name
        : null;
  }

  final identities = <String, String>{};
  String identity(String name) =>
      identities.putIfAbsent(normalizedPersonName(name), () {
        final mentions = extractPersonMentions(name, people);
        if (mentions.length == 1 &&
            mentions.single.matches.length == 1 &&
            normalizedPersonName(mentions.single.name) ==
                normalizedPersonName(name)) {
          return 'id:${mentions.single.matches.single.id}';
        }
        return 'name:${normalizedPersonName(name)}';
      });

  void connect(
      String first, String second, RelationshipType type, String source) {
    final a = identity(first);
    final b = identity(second);
    if (a == b ||
        isDuplicateConnection(
            existing: connections.map((c) => (
                  person1Id: identity(c.person1Name),
                  person2Id: identity(c.person2Name),
                  relationshipType: c.type.name
                )),
            person1Id: a,
            person2Id: b,
            type: type)) {
      return;
    }
    connections.add(TranscriptConnection(
        person1Name: first,
        person2Name: second,
        type: type,
        sourceText: source));
  }

  List<String>? names(String raw) {
    // A bounded grammatical list must contain a final conjunction.
    if (raw.contains(',') &&
        !_pattern(r',?\s+(?:and|und)\s+[^,]+$').hasMatch(raw)) {
      return null;
    }
    final parts =
        raw.split(_pattern(r',\s*(?:(?:and|und)\s+)?|\s+(?:and|und)\s+'));
    if (parts.length > 4) return null;
    final result = parts.map(personName).toList();
    return result.any((name) => name == null) ? null : result.cast<String>();
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
      '^(.*?)\\s+(?:is|ist|are|sind)\\s+(?:(?:the|a|an|der|die|das|ein|eine)\\s+)?($relation)\\s+(?:of|von)\\s+(.+?)(?:\\s+ist)?\$');
  const ownership = r"(?:[’']s|s|[’'])";
  final possessive = _pattern('^(.*?)\\s+(?:is|ist)\\s+'
      r'(?!(?:his|hers|its|ours|yours|theirs)\b)'
      '(.+?)$ownership\\s+($relation)\$');
  final reversePossessive =
      _pattern(r'^(?!(?:his|hers|its|ours|yours|theirs)\b)'
          '(.+?)$ownership\\s+($relation)\\s+(?:is|ist)\\s+(.+)\$');
  final appositive = _pattern(
      '^(.+?),\\s*((?:(?:the|a|an|der|die|das|ein|eine)\\s+)?(?:$relation)\\s+(?:of|von)\\s+[^,]+|[^,]+$ownership\\s+(?:$relation))(?=,|\$)');
  final paired = _pattern(
      '^(.*?)\\s+(?:and|und)\\s+(.+?)\\s+(?:are|sind)\\s+(${transcriptRelationshipPlurals.keys.join('|')})\$');
  final married = _pattern(
      r'^(.*?)\s+(?:is\s+married\s+to\s+(.+)|ist\s+mit\s+(.+)\s+verheiratet)$');
  final hasRole = _pattern(
      '^(.*?)\\s+(?:has|hat|have|haben)\\s+(?:(?:a|an|einen?|eine)\\s+)?($relation)\\s+(?:(?:named|called|namens)\\s+)?(.+)\$');
  final actions = <(RegExp, RelationshipType)>[
    (
      _pattern(
          r'^(.*?)\s+(?:is\s+friends\s+with|ist\s+befreundet\s+mit)\s+(.+)$'),
      RelationshipType.friend
    ),
    (
      _pattern(r'^(.*?)\s+ist\s+mit\s+(.+)\s+befreundet$'),
      RelationshipType.friend
    ),
    (
      _pattern(
          r'^(.*?)\s+(?:is\s+in\s+a\s+relationship\s+with|ist\s+zusammen\s+mit)\s+(.+)$'),
      RelationshipType.partner
    ),
    (
      _pattern(r'^(.*?)\s+ist\s+mit\s+(.+)\s+zusammen$'),
      RelationshipType.partner
    ),
    (
      _pattern(
          r'^(.*?)\s+(?:is\s+divorced\s+from|ist\s+geschieden\s+von)\s+(.+)$'),
      RelationshipType.exPartner
    ),
    (
      _pattern(r'^(.*?)\s+ist\s+von\s+(.+)\s+geschieden$'),
      RelationshipType.exPartner
    ),
    (_pattern(r'^(.*?)\s+mentors\s+(.+)$'), RelationshipType.mentor),
    (
      _pattern(r'^(.*?)\s+(?:adopted|adoptiert|adoptierte)\s+(.+)$'),
      RelationshipType.adoptiveParent
    ),
    (
      _pattern(r'^(.*?)\s+hat\s+(.+)\s+adoptiert$'),
      RelationshipType.adoptiveParent
    ),
    (
      _pattern(r'^(.*?)\s+(?:teaches|unterrichtet)\s+(.+)$'),
      RelationshipType.teacher
    ),
    (
      _pattern(r'^(.*?)\s+(?:reports\s+to|berichtet\s+an)\s+(.+)$'),
      RelationshipType.directReport
    ),
    (
      _pattern(r'^(.*?)\s+(?:knows|kennt)\s+(.+)$'),
      RelationshipType.acquaintance
    ),
    (
      _pattern(
          r'^(.*?)\s+(?:works?\s+with|arbeitet\s+mit)\s+(.+?)(?:\s+zusammen)?$'),
      RelationshipType.colleague
    ),
    (
      _pattern(r'^(.*?)\s+betreut\s+(.+)\s+als\s+Mentor(?:in)?$'),
      RelationshipType.mentor
    ),
    (
      _pattern(r'^(.*?)\s+ist\s+(.+)\s+direkt\s+unterstellt$'),
      RelationshipType.directReport
    ),
  ];
  final mutualActions = <(RegExp, RelationshipType)>[
    (
      _pattern(
          r'^(.*?)\s+(?:and|und)\s+(.+?)\s+(?:work\s+together|arbeiten\s+zusammen)$'),
      RelationshipType.colleague
    ),
    (
      _pattern(
          r'^(.*?)\s+(?:and|und)\s+(.+?)\s+(?:know\s+each\s+other|kennen\s+(?:sich|einander))$'),
      RelationshipType.acquaintance
    ),
  ];
  final employer = _pattern(
      r'^(.*?)\s+(?:(?:works?\s+(?:at|for)|arbeit(?:et|en)\s+bei)\s+(.+)|bei\s+(.+)\s+arbeitet)$');
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
      r'was|wurde|mentors|adopted|adoptiert|adoptierte|teaches|unterrichtet|reports|berichtet|knows|kennt|betreut)\b';
  const predicate = '(?:$finitePredicate|(?:bei|in)\\b)';
  final explicitStart = _pattern('^(.+?)\\s+$finitePredicate');
  final implicitStart = _pattern('^(?:$finitePredicate|bei\\s+|'
      'in\\s+.+\\s+(?:wohnt|wohnte)\\b|'
      '(?:(?:the|a|an|der|die|das|ein|eine)\\s+)?(?:$relation)\\s+(?:of|von)\\s+)');
  final relativeStart = _pattern(r'^(?:who|which|der|die)\s+');
  final clauseSeparator = _pattern(r',\s*(?:(?:and|und)\s+)?|\s+(?:and|und)\s+|'
      '\\s+(?=(?:who|which)\\s+|(?:der|die)\\s+'
      '(?!$profession\\s+(?:of|von)\\b)(?:$predicate|(?:ein|eine)\\b|$profession\\b))');
  final correction =
      _pattern(r'^(.*?)\s+(wohnt\s+in|lives\s+(?:in|at))\s+[^,]+,\s*'
          r'(?:nein|no|sorry|ich\s+meine|I\s+mean),?\s+(?:in|at)\s+([^,]+)$');
  for (final sentence in _transcriptAssertions(text, (tail) {
    final explicit = explicitStart.firstMatch(tail);
    return explicit != null && personName(explicit.group(1)!) != null;
  })) {
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
        names('${pair.group(1)} and ${pair.group(2)}') != null) {
      final members = names('${pair.group(1)} and ${pair.group(2)}')!;
      final type = transcriptRelationshipWords[
          transcriptRelationshipPlurals[pair.group(3)!.toLowerCase()]]!;
      // Explicit collective roles establish all pairs; plural romantic roles
      // do not say which group members are partners of one another.
      if (members.length == 2 ||
          {
            RelationshipType.friend,
            RelationshipType.sibling,
            RelationshipType.halfSibling,
            RelationshipType.stepSibling,
            RelationshipType.cousin,
            RelationshipType.colleague,
            RelationshipType.roommate,
            RelationshipType.classmate,
            RelationshipType.teammate,
            RelationshipType.businessPartner,
            RelationshipType.neighbour,
            RelationshipType.acquaintance,
          }.contains(type)) {
        for (var i = 0; i < members.length; i++) {
          for (var j = i + 1; j < members.length; j++) {
            connect(members[i], members[j], type, body);
          }
        }
      }
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
    final mutual = mutualActions.any((rule) => rule.$1.hasMatch(body));
    for (final separator
        in mutual ? <RegExpMatch>[] : clauseSeparator.allMatches(body)) {
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
      if (_pattern(r'^which\s+').hasMatch(clause)) {
        subject = antecedent = null;
        continue;
      }
      final relative =
          _pattern(r'^(?:who|which|der|die)\s+').firstMatch(clause);
      if (relative != null) {
        subject = antecedent;
        clause = clause.substring(relative.end);
      }
      if (relative != null ||
          _pattern('^(?:$predicate|(?:the|a|an|der|die|das|ein|eine)\\s+)')
              .hasMatch(clause)) {
        if (subject == null) continue;
        // A coordinated role can omit its copula; German relatives put it last.
        if (_pattern(
                '^(?:(?:the|a|an|der|die|das|ein|eine)\\s+)?($relation)\\s+(?:of|von)\\s+')
            .hasMatch(clause)) {
          clause = 'is ${clause.replaceFirst(_pattern(r'\s+ist$'), '')}';
        }
        clause = '$subject $clause';
      } else {
        subject = null;
        antecedent = null;
      }
      // English chef is an occupation; German Chef explicitly means boss.
      if (_pattern(r'\b(?:is|are|has|have)\b').hasMatch(clause) &&
          _pattern(r'\bchef\b').hasMatch(clause)) {
        continue;
      }
      var expanded = false;
      String? expandedSubject;
      String? expandedAntecedent;
      final listed = direct.firstMatch(clause);
      if (listed != null) {
        final subjects = names(listed.group(1)!);
        final objects = names(listed.group(3)!);
        if (subjects != null &&
            objects != null &&
            (subjects.length > 1 || objects.length > 1) &&
            (subjects.length == 1 || objects.length == 1)) {
          final type = transcriptRelationshipWords[
              listed.group(2)!.toLowerCase().replaceAll(RegExp(r'\s+'), ' ')]!;
          for (final first in subjects) {
            for (final second in objects) {
              connect(first, second, type, source);
            }
          }
          expandedSubject = subjects.length == 1 ? subjects.single : null;
          expandedAntecedent = objects.length == 1 ? objects.single : null;
          expanded = true;
        }
      }
      final held = hasRole.firstMatch(clause);
      if (!expanded && held != null) {
        final owner = personName(held.group(1)!);
        final holders = names(held.group(3)!);
        if (owner != null && holders != null) {
          final type = transcriptRelationshipWords[
              held.group(2)!.toLowerCase().replaceAll(RegExp(r'\s+'), ' ')]!;
          for (final holder in holders) {
            connect(holder, owner, type, source);
          }
          expandedSubject = owner;
          expandedAntecedent = holders.length == 1 ? holders.single : null;
          expanded = true;
        }
      }
      for (final (pattern, type) in actions) {
        if (expanded) break;
        final action = pattern.firstMatch(clause);
        if (action == null) continue;
        final first = personName(action.group(1)!);
        final second = personName(action.group(2)!);
        if (first != null && second != null) {
          connect(first, second, type, source);
          expandedSubject = first;
          expandedAntecedent = second;
          expanded = true;
        }
      }
      for (final (pattern, type) in mutualActions) {
        if (expanded) break;
        final action = pattern.firstMatch(clause);
        if (action == null) continue;
        final first = personName(action.group(1)!);
        final second = personName(action.group(2)!);
        if (first != null && second != null) {
          connect(first, second, type, source);
          expanded = true;
        }
      }
      if (expanded) {
        subject = expandedSubject;
        antecedent = expandedAntecedent;
        continue;
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
        final type = transcriptRelationshipWords[
            word.toLowerCase().replaceAll(RegExp(r'\s+'), ' ')]!;
        connect(first, second, type, source);
        continue;
      }
      match = employer.firstMatch(clause);
      if (match != null) {
        final workers = names(match.group(1)!);
        if (workers != null) {
          subject = workers.length == 1 ? workers.single : null;
          antecedent = null;
          for (final worker in workers) {
            fact(worker, (match.group(2) ?? match.group(3))!.trim(), source,
                company: true);
          }
          continue;
        }
      }
      match = sharedResidence.firstMatch(clause);
      if (match != null) {
        final residents = names('${match.group(1)} and ${match.group(2)}');
        if (residents != null) {
          for (final resident in residents) {
            fact(resident, clause, source);
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
          subject = name;
          antecedent = null;
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
