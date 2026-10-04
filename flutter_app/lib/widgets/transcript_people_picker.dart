import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import '../models/person.dart';
import '../models/event.dart';
import '../relationships/relationship_text.dart';
import '../relationships/relationship_type.dart';
import '../services/database_service.dart';
import '../services/person_mentions.dart';
import '../services/transcript_connections.dart';
import '../services/transcript_connection_store.dart';

typedef DetectedConnection = ({
  Person person1,
  Person person2,
  RelationshipType type,
  String sourceText
});
typedef DetectedPersonFact = ({
  Person person,
  String value,
  String sourceText,
  bool isCompany
});

/// Recognition stays on this device. Draft people are persisted only on Save.
class TranscriptPeopleController extends ChangeNotifier {
  final TextEditingController text;
  final DatabaseService database;
  List<Person> _people = [];
  List<PersonMention> _mentions = [];
  final _drafts = <String, Person>{};
  final _choices = <String, String>{};
  final _dismissed = <String>{};
  final _dismissedIds = <String>{};
  TranscriptConnections _information =
      const TranscriptConnections(connections: [], facts: []);
  final _dismissedConnections = <String>{};
  final _dismissedFacts = <String>{};
  Set<String> _preferredIds;
  bool _disposed = false;
  bool _loadFailed = false;

  TranscriptPeopleController(this.text, this.database,
      {Set<String> preferredIds = const {}})
      : _preferredIds = preferredIds {
    text.addListener(_recognize);
    _reload();
  }

  Future<void> _reload() async {
    try {
      final people = await database.getPersons();
      if (_disposed) return;
      _people = people;
      _loadFailed = false;
    } catch (_) {
      if (_disposed) return;
      _loadFailed = true;
    }
    _recognize();
  }

  void _recognize() {
    if (_disposed) return;
    _information = extractTranscriptConnections(text.text, _people);
    final names = {
      for (final connection in _information.connections) ...[
        connection.person1Name,
        connection.person2Name
      ],
      for (final fact in _information.facts) fact.personName,
    };
    final candidates = <Person>[];
    for (final name in names) {
      final key = normalizedPersonName(name);
      if (_people.any((p) => [p.name, ...p.aliases, p.name.split(' ').first]
          .any((n) => normalizedPersonName(n) == key))) {
        continue;
      }
      final fuller = names
          .where((n) => normalizedPersonName(n).startsWith('$key '))
          .toSet();
      if (fuller.length == 1) continue;
      candidates.add(_drafts.putIfAbsent(key, () => Person(name: name)));
    }
    _mentions = extractPersonMentions(text.text, [..._people, ...candidates]);
    notifyListeners();
  }

  bool _isDismissed(String name) {
    final key = normalizedPersonName(name);
    return _dismissed
        .any((dismissed) => key == dismissed || key.startsWith('$dismissed '));
  }

  Person? _person(PersonMention mention) {
    if (_isDismissed(mention.name)) return null;
    final key = normalizedPersonName(mention.name);
    final Person? person;
    if (mention.matches.isEmpty) {
      person = _drafts.putIfAbsent(key, () => Person(name: mention.name));
    } else if (mention.matches.length == 1) {
      person = mention.matches.single;
    } else {
      final preferred =
          mention.matches.where((p) => _preferredIds.contains(p.id)).toList();
      person =
          mention.matches.where((p) => p.id == _choices[key]).firstOrNull ??
              (preferred.length == 1 ? preferred.single : null);
    }
    return person != null && !_dismissedIds.contains(person.id) ? person : null;
  }

  List<Person> get selectedPeople {
    final selected = <String, Person>{};
    for (final mention in _mentions) {
      final person = _person(mention);
      if (person != null) selected[person.id] = person;
    }
    return selected.values.toList();
  }

  void preferPersonIds(Set<String> ids) {
    _preferredIds = ids;
    _dismissedIds.removeAll(ids);
    notifyListeners();
  }

  Person? _resolveName(String name) {
    final key = normalizedPersonName(name);
    final mention =
        _mentions.where((m) => normalizedPersonName(m.name) == key).firstOrNull;
    if (mention != null) return _person(mention);
    final matches = selectedPeople
        .where((p) => [p.name, ...p.aliases, p.name.split(' ').first]
            .any((n) => normalizedPersonName(n) == key))
        .toList();
    return matches.length == 1 ? matches.single : null;
  }

  String _connectionKey(DetectedConnection c) =>
      c.person1.id.compareTo(c.person2.id) <= 0
          ? '${c.person1.id}:${c.type.name}:${c.person2.id}'
          : '${c.person2.id}:${inverseOf(c.type).name}:${c.person1.id}';

  String _factKey(DetectedPersonFact f) =>
      '${f.person.id}:${f.isCompany}:${normalizedPersonName(f.value).replaceAll(RegExp(r"[.!?]+$"), "")}';

  List<DetectedConnection> get connections {
    final result = <DetectedConnection>[];
    for (final c in _information.connections) {
      final first = _resolveName(c.person1Name);
      final second = _resolveName(c.person2Name);
      if (first == null || second == null || first.id == second.id) continue;
      final resolved = (
        person1: first,
        person2: second,
        type: c.type,
        sourceText: c.sourceText
      );
      if (!_dismissedConnections.contains(_connectionKey(resolved))) {
        result.add(resolved);
      }
    }
    return result;
  }

  List<DetectedPersonFact> get facts {
    final result = <DetectedPersonFact>[];
    for (final f in _information.facts) {
      final person = _resolveName(f.personName);
      if (person == null) continue;
      final resolved = (
        person: person,
        value: f.value,
        sourceText: f.sourceText,
        isCompany: f.isCompany
      );
      if (!_dismissedFacts.contains(_factKey(resolved))) result.add(resolved);
    }
    return result;
  }

  void dismissConnection(DetectedConnection connection) {
    _dismissedConnections.add(_connectionKey(connection));
    notifyListeners();
  }

  void dismissFact(DetectedPersonFact fact) {
    _dismissedFacts.add(_factKey(fact));
    notifyListeners();
  }

  Future<void> saveInformation(Event event) async {
    final people = await database.getPersons();
    Person saved(Person person) {
      final byId = people.where((p) => p.id == person.id).firstOrNull;
      if (byId != null) return byId;
      return people.singleWhere((p) => [p.name, ...p.aliases].any(
          (n) => normalizedPersonName(n) == normalizedPersonName(person.name)));
    }

    await saveTranscriptInformation(database, event, [
      for (final c in connections)
        (
          person1: saved(c.person1),
          person2: saved(c.person2),
          type: c.type,
          sourceText: c.sourceText
        )
    ], [
      for (final f in facts)
        (
          person: saved(f.person),
          value: f.value,
          sourceText: f.sourceText,
          isCompany: f.isCompany
        )
    ]);
  }

  /// Re-read names before save, including the last transcript tail or user edit.
  Future<List<Person>> peopleForSave() async {
    await _reload();
    return selectedPeople;
  }

  void dismiss(String name) {
    final key = normalizedPersonName(name);
    final known =
        _people.where((p) => normalizedPersonName(p.name) == key).toList();
    if (known.isEmpty) {
      _dismissed.add(key);
    } else {
      _dismissedIds.addAll(known.map((p) => p.id));
    }
    notifyListeners();
  }

  void choose(PersonMention mention, Person person) {
    _choices[normalizedPersonName(mention.name)] = person.id;
    _dismissedIds.remove(person.id);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    text.removeListener(_recognize);
    super.dispose();
  }
}

class TranscriptPeoplePicker extends StatelessWidget {
  final TranscriptPeopleController controller;
  final Set<String> selectedNames;
  final Set<String> selectedIds;

  const TranscriptPeoplePicker(
      {super.key,
      required this.controller,
      this.selectedNames = const {},
      this.selectedIds = const {}});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final l10n = AppLocalizations.of(context);
          final selected = controller.selectedPeople
              .where((p) =>
                  !selectedIds.contains(p.id) &&
                  !selectedNames.contains(normalizedPersonName(p.name)))
              .toList();
          final ambiguous = controller._mentions.where((m) =>
              m.matches.length > 1 &&
              !controller._isDismissed(m.name) &&
              controller._person(m) == null);
          if (controller._loadFailed) return Text(l10n.storyPeopleLoadFailed);
          final connections = controller.connections;
          final facts = controller.facts;
          if (selected.isEmpty &&
              ambiguous.isEmpty &&
              connections.isEmpty &&
              facts.isEmpty) {
            return const SizedBox.shrink();
          }
          return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.storyPeopleDetectedHelp,
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 4, children: [
                  for (final person in selected)
                    Chip(
                        label: Text(person.name),
                        avatar: controller._people.any((p) => p.id == person.id)
                            ? null
                            : const Icon(Icons.person_add_alt_1, size: 18),
                        onDeleted: () => controller.dismiss(person.name)),
                ]),
                for (final mention in ambiguous) ...[
                  Text(l10n.storyPeopleAmbiguous(mention.name)),
                  Wrap(spacing: 8, runSpacing: 4, children: [
                    for (final person in mention.matches)
                      ActionChip(
                          label: Text([
                            person.name,
                            if (person.lifeDatesLabel(
                                    locale: l10n.localeName) !=
                                null)
                              person.lifeDatesLabel(locale: l10n.localeName)!
                          ].join(' · ')),
                          onPressed: () => controller.choose(mention, person)),
                  ]),
                ],
                if (connections.isNotEmpty || facts.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(l10n.storyInformationDetectedHeading,
                      style: Theme.of(context).textTheme.titleSmall),
                  Text(l10n.storyInformationDetectedHelp,
                      style: Theme.of(context).textTheme.bodySmall),
                  for (final connection in connections)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.link),
                      title: Text(
                          '${connection.person1.name} · ${RelationshipText.roleOfLabel(l10n, connection.type, connection.person2.name)}'),
                      trailing: IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: l10n.storyInformationRemove,
                          onPressed: () =>
                              controller.dismissConnection(connection)),
                    ),
                  for (final fact in facts)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading:
                          Icon(fact.isCompany ? Icons.business : Icons.notes),
                      title: Text('${fact.person.name}: ${fact.sourceText}'),
                      trailing: IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: l10n.storyInformationRemove,
                          onPressed: () => controller.dismissFact(fact)),
                    ),
                ],
                const SizedBox(height: 8),
              ]);
        });
  }
}

/// Reuse names/aliases at save time; never write speculative people on opening a form.
Future<List<String>> saveStoryPeople(
    DatabaseService db, Iterable<Person> selection) async {
  final known = await db.getPersons();
  final ids = <String>{};
  for (final person in selection) {
    final byId = known.where((p) => p.id == person.id).firstOrNull;
    final matches = known
        .where((p) => [p.name, ...p.aliases].any((name) =>
            normalizedPersonName(name) == normalizedPersonName(person.name)))
        .toList();
    if (byId == null && matches.length > 1) {
      throw StateError('Choose the person with this name');
    }
    final resolved = byId ?? matches.firstOrNull ?? person;
    if (!known.any((p) => p.id == resolved.id)) {
      await db.savePerson(resolved);
      known.add(resolved);
    }
    ids.add(resolved.id);
  }
  return ids.toList();
}
