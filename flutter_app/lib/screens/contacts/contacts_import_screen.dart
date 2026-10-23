import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../models/person.dart';
import '../../services/contact_import_service.dart';
import '../../services/database_service.dart';
import '../../services/interaction_feedback.dart';

class ContactsImportScreen extends StatefulWidget {
  final ContactImportService? service;
  const ContactsImportScreen({super.key, this.service});

  @override
  State<ContactsImportScreen> createState() => _ContactsImportScreenState();
}

class _ContactsImportScreenState extends State<ContactsImportScreen> {
  late final _service = widget.service ?? ContactImportService();
  List<Person> _people = [], _existing = [];
  final Set<String> _selected = {};
  bool _busy = false, _loaded = false, _permissionDenied = false;
  String? _error;

  Future<void> _load(bool device) async {
    final database = context.read<DatabaseService>();
    setState(() {
      _busy = true;
      _error = null;
      _permissionDenied = false;
    });
    try {
      final people =
          await (device ? _service.readDevice() : _service.readFile());
      if (people == null) return;
      final existing = await database.getPersons();
      final unique = <Person>[];
      for (final person in people) {
        if (!ContactImportService.isDuplicate(person, unique)) {
          unique.add(person);
        }
      }
      if (!mounted) return;
      setState(() {
        _people = unique;
        _existing = existing;
        _loaded = true;
        _selected.clear();
        _selected.addAll(unique
            .where(
                (person) => !ContactImportService.isDuplicate(person, existing))
            .map((person) => person.id));
      });
    } on ContactPermissionDenied {
      if (mounted) {
        setState(() {
          _permissionDenied = true;
          _error = AppLocalizations.of(context).contactsPermissionDenied;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
            () => _error = AppLocalizations.of(context).contactsReadFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    var imported = 0;
    try {
      final db = context.read<DatabaseService>();
      _existing = await db.getPersons();
      for (final person in _people
          .where((person) => _selected.contains(person.id))
          .toList()) {
        if (!ContactImportService.isDuplicate(person, _existing)) {
          await db.savePerson(person);
          _existing.add(person);
          imported++;
        }
        _selected.remove(person.id);
      }
      if (mounted) {
        context.read<InteractionFeedback?>()?.play(FeedbackCue.success);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(AppLocalizations.of(context).contactsImported(imported))));
      }
    } catch (_) {
      if (mounted) {
        setState(
            () => _error = AppLocalizations.of(context).contactsSaveFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopScope(
        canPop: !_busy,
        child: Scaffold(
          appBar: AppBar(title: Text(l10n.contactsImportTitle)),
          body: Column(children: [
            Padding(
                padding: const EdgeInsets.all(16),
                child: Column(children: [
                  Text(l10n.contactsImportHelp),
                  const SizedBox(height: 12),
                  Wrap(spacing: 12, runSpacing: 8, children: [
                    if (_service.supportsDeviceContacts)
                      OutlinedButton.icon(
                          onPressed: _busy ? null : () => _load(true),
                          icon: const Icon(Icons.contacts),
                          label: Text(l10n.contactsFromDevice)),
                    OutlinedButton.icon(
                        onPressed: _busy ? null : () => _load(false),
                        icon: const Icon(Icons.upload_file),
                        label: Text(l10n.contactsFromFile)),
                  ]),
                  if (_busy) const LinearProgressIndicator(),
                  if (_error != null)
                    Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  if (_permissionDenied)
                    TextButton(
                        onPressed: () async {
                          try {
                            await _service.openPermissionSettings();
                          } catch (_) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                      content: Text(l10n.contactsReadFailed)));
                            }
                          }
                        },
                        child: Text(l10n.contactsOpenSettings)),
                ])),
            if (_loaded && _people.isEmpty) Text(l10n.contactsEmpty),
            Expanded(
                child: ListView(children: [
              for (final person in _people)
                CheckboxListTile(
                    value: _selected.contains(person.id),
                    onChanged: _busy ||
                            ContactImportService.isDuplicate(person, _existing)
                        ? null
                        : (value) => setState(() {
                              if (value == true) {
                                _selected.add(person.id);
                              } else {
                                _selected.remove(person.id);
                              }
                            }),
                    title: Text(person.name),
                    subtitle: Text(
                        ContactImportService.isDuplicate(person, _existing)
                            ? l10n.contactsAlreadyAdded
                            : [person.email, person.phoneNumber]
                                .whereType<String>()
                                .join(' · '))),
            ])),
            SafeArea(
                top: false,
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: FilledButton(
                      onPressed: _busy || _selected.isEmpty ? null : _import,
                      child:
                          Text(l10n.contactsImportSelected(_selected.length)),
                    ))),
          ]),
        ));
  }
}
