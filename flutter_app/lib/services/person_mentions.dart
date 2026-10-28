import '../models/person.dart';
import 'transcript_relationship_vocabulary.dart';

String normalizedPersonName(String name) => name
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll('’', "'")
    .toLowerCase();

class PersonMention {
  final String name;
  final List<Person> matches;

  const PersonMention({required this.name, required this.matches});
}

class _Occurrence {
  final int start;
  final int end;
  final PersonMention mention;

  const _Occurrence(this.start, this.end, this.mention);
}

/// Recognizes known names locally, and unfamiliar names after explicit human
/// cues. This deliberately does not treat capitalized German nouns as names.
List<PersonMention> extractPersonMentions(String text, List<Person> people) {
  final names = <String, Map<String, Person>>{};
  for (final person in people.where((person) => !person.isDeleted)) {
    for (final name in [person.name, ...person.aliases]) {
      final normalized = normalizedPersonName(name);
      if (normalized.isEmpty) continue;
      names.putIfAbsent(normalized, () => {})[person.id] = person;
    }
    final parts = normalizedPersonName(person.name).split(' ');
    if (parts.length > 1) {
      names.putIfAbsent(parts.first, () => {})[person.id] = person;
    }
  }

  final word = RegExp(r"[\p{L}\p{M}\p{N}'’\-]", unicode: true);
  bool boundary(int index) =>
      index < 0 ||
      index >= text.length ||
      !word.hasMatch(text.substring(index, index + 1));
  // Bare German genitive -s needs a relationship cue so plurals such as
  // "Annas kamen" cannot introduce a partial name match.
  final possessive = RegExp(
      r"^(?:['’]s?(?:$|[^\p{L}\p{M}\p{N}'’\-])|s\s+(?:" +
          transcriptHumanRolePattern +
          r')\b)',
      caseSensitive: false,
      unicode: true);
  final occurrences = <_Occurrence>[];
  for (final entry in names.entries) {
    final pattern = entry.key
        .split(' ')
        .map(RegExp.escape)
        .join(r'\s+')
        .replaceAll("'", "['’]");
    for (final match in RegExp(pattern, caseSensitive: false, unicode: true)
        .allMatches(text)) {
      if (boundary(match.start - 1) &&
          (boundary(match.end) ||
              possessive.hasMatch(text.substring(match.end)))) {
        occurrences.add(_Occurrence(
            match.start,
            match.end,
            PersonMention(
                name: match.group(0)!, matches: entry.value.values.toList())));
      }
    }
  }

  final cues = RegExp(
      '\\b(?:$transcriptHumanRolePattern|'
      r'herr|frau|grandma|grandpa|mr\.?|mrs\.?|ms\.?|named|called|namens|heißt|heisst)\s+',
      caseSensitive: false,
      unicode: true);
  const capitalized = r"\p{Lu}[\p{L}\p{M}]*(?:[-'’]\p{L}[\p{L}\p{M}]*)*";
  final personName = RegExp(
      '^(?:(?:von|van|de|der|den|zu|zur)\\s+)*$capitalized(?:\\s+(?:(?:von|van|de|der|den|zu|zur)\\s+)*$capitalized){0,3}',
      unicode: true);
  final academicTitle = RegExp(r'^(?:(?:dr|prof)\.?(?:\s+|$))+',
      caseSensitive: false, unicode: true);
  final humanRole = RegExp('^(?:$transcriptHumanRolePattern)\$',
      caseSensitive: false, unicode: true);
  final namedRolePrefix = RegExp('^(?:$transcriptHumanRolePattern)\\s+',
      caseSensitive: false, unicode: true);
  final conjunction = RegExp(r'\b(?:and|und)\b', caseSensitive: false);
  final nameSeparator = RegExp(
      r'^(?:,\s*(?:(?:and|und)\s+)?|\s+(?:and|und)\s+)',
      caseSensitive: false);
  final organization =
      RegExp(r'\b(?:GmbH|AG|Inc|Ltd|LLC|Corp)\.?$', caseSensitive: false);
  List<(int, int, String)> namesAt(int offset, {bool allowList = false}) {
    final spans = <(int, int, String)>[];
    var hasConjunction = false;
    for (var i = 0; i < 4; i++) {
      final start =
          offset + (academicTitle.firstMatch(text.substring(offset))?.end ?? 0);
      final match = personName.firstMatch(text.substring(start));
      if (match == null || !boundary(start + match.end)) break;
      final name = match.group(0)!;
      if (organization.hasMatch(name) ||
          namedRolePrefix.hasMatch(name) ||
          RegExp(r"['’]s$").hasMatch(name)) {
        break;
      }
      spans.add((start, start + match.end, name));
      if (!allowList) break;
      final separator =
          nameSeparator.firstMatch(text.substring(start + match.end));
      if (separator == null) break;
      hasConjunction |= conjunction.hasMatch(separator.group(0)!);
      offset = start + match.end + separator.end;
    }
    return spans.length > 1 && !hasConjunction ? [spans.first] : spans;
  }

  for (final cue in cues.allMatches(text)) {
    if (!boundary(cue.start - 1)) continue;
    // A role followed by "of/von" describes a relationship, not a name particle.
    if (!RegExp(r'^(?:herr|frau|mr\.?|mrs\.?|ms\.?)$', caseSensitive: false)
            .hasMatch(cue.group(0)!.trim()) &&
        RegExp(r'^(?:of|von)\s+', caseSensitive: false)
            .hasMatch(text.substring(cue.end))) {
      continue;
    }
    final isHumanRole = humanRole.hasMatch(cue.group(0)!.trim());
    final copula = isHumanRole
        ? RegExp(r'^(?:is|ist|are|sind)\s+', caseSensitive: false)
            .firstMatch(text.substring(cue.end))
        : null;
    for (final (start, end, name)
        in namesAt(cue.end + (copula?.end ?? 0), allowList: isHumanRole)) {
      final key = normalizedPersonName(name);
      // A surname alone identifies someone only after an explicit human cue.
      final matches = names[key]?.values.toList() ??
          {
            for (final person in people)
              if (!person.isDeleted &&
                  normalizedPersonName(person.name).endsWith(' $key'))
                person.id: person
          }.values.toList();
      occurrences.add(
          _Occurrence(start, end, PersonMention(name: name, matches: matches)));
    }
  }

  // Naming a pet does not mention a human with the same name. Filter each
  // occurrence so an independent human mention elsewhere still survives.
  final petCue = RegExp(
      r'\b(hund|hunde|hündin|welpe|katze|katzen|kater|haustier|kaninchen|pferd|vogel|'
      r'hamster|dog|dogs|puppy|cat|cats|kitten|pet|pets|rabbit|horse|bird)\s+'
      r'(?:(?:(?:ist|is)\s+)?(?:namens|heißt|heisst|named|called)\s+)?',
      caseSensitive: false,
      unicode: true);
  for (final cue in petCue.allMatches(text)) {
    if (!boundary(cue.start - 1)) continue;
    for (final (start, end, _) in namesAt(cue.end,
        allowList: const {'hunde', 'katzen', 'dogs', 'cats', 'pets'}
            .contains(cue.group(1)!.toLowerCase()))) {
      occurrences.removeWhere(
          (occurrence) => occurrence.start >= start && occurrence.end <= end);
    }
  }
  // A familiar human name inside a company name still denotes the company.
  final companies = RegExp(
      '$capitalized(?:\\s+$capitalized){0,3}\\s+(?:GmbH|AG|Inc|Ltd|LLC|Corp)\\b',
      unicode: true);
  for (final company in companies.allMatches(text)) {
    occurrences.removeWhere((occurrence) =>
        occurrence.start >= company.start && occurrence.end <= company.end);
  }

  // Keep full names ahead of overlapping first names and aliases.
  occurrences.sort((a, b) {
    final length = (b.end - b.start).compareTo(a.end - a.start);
    return length != 0 ? length : a.start.compareTo(b.start);
  });
  final selected = <_Occurrence>[];
  for (final occurrence in occurrences) {
    if (!selected.any((other) =>
        occurrence.start < other.end && other.start < occurrence.end)) {
      selected.add(occurrence);
    }
  }
  selected.sort((a, b) => a.start.compareTo(b.start));

  final result = <PersonMention>[];
  final seen = <String>{};
  for (final occurrence in selected) {
    final mention = occurrence.mention;
    final name = normalizedPersonName(mention.name);
    if (mention.matches.isEmpty) {
      final fuller = selected
          .where((other) =>
              normalizedPersonName(other.mention.name).startsWith('$name '))
          .toList();
      if (fuller
              .map((other) => normalizedPersonName(other.mention.name))
              .toSet()
              .length ==
          1) {
        continue;
      }
    }
    final ids = mention.matches.map((person) => person.id).toList()..sort();
    final key = ids.isEmpty ? 'name:$name' : 'ids:${ids.join(',')}';
    if (seen.add(key)) result.add(mention);
  }
  return result;
}
