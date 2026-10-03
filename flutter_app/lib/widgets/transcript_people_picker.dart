import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import '../models/person.dart';
import '../services/database_service.dart';
import '../services/person_mentions.dart';

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
  bool _disposed = false;
  bool _loadFailed = false;

  TranscriptPeopleController(this.text, this.database) {
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
    _mentions = extractPersonMentions(text.text, _people);
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
      person = mention.matches.where((p) => p.id == _choices[key]).firstOrNull;
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
          if (selected.isEmpty && ambiguous.isEmpty) {
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
