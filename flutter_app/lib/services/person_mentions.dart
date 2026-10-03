import '../models/person.dart';

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
  final possessive = RegExp(r"^['’]s(?:$|[^\p{L}\p{M}\p{N}'’\-])",
      caseSensitive: false, unicode: true);
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
      r'\b(?:schwester|bruder|onkel|tante|oma|opa|mutter|vater|cousine|cousin|'
      r'herr|frau|sister|brother|uncle|aunt|grandma|grandpa|mother|father|'
      r'mr\.?|mrs\.?|ms\.?|named|called|namens|heißt|heisst)\s+',
      caseSensitive: false,
      unicode: true);
  const capitalized = r"\p{Lu}[\p{L}\p{M}]*(?:[-'’]\p{L}[\p{L}\p{M}]*)*";
  final personName = RegExp(
      '^(?:(?:von|van|de|der|den|zu|zur)\\s+)*$capitalized(?:\\s+(?:(?:von|van|de|der|den|zu|zur)\\s+)*$capitalized){0,3}',
      unicode: true);
  final academicTitle = RegExp(r'^(?:(?:dr|prof)\.?(?:\s+|$))+',
      caseSensitive: false, unicode: true);
  for (final cue in cues.allMatches(text)) {
    if (!boundary(cue.start - 1)) continue;
    final start =
        cue.end + (academicTitle.firstMatch(text.substring(cue.end))?.end ?? 0);
    final match = personName.firstMatch(text.substring(start));
    if (match == null || !boundary(start + match.end)) continue;
    final name = match.group(0)!;
    final key = normalizedPersonName(name);
    // A surname alone identifies someone only after an explicit human cue.
    final matches = names[key]?.values.toList() ??
        {
          for (final person in people)
            if (!person.isDeleted &&
                normalizedPersonName(person.name).endsWith(' $key'))
              person.id: person
        }.values.toList();
    occurrences.add(_Occurrence(
        start, start + match.end, PersonMention(name: name, matches: matches)));
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
