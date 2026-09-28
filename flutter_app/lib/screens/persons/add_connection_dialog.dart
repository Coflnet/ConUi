import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../models/models.dart';
import '../../relationships/relationship_text.dart';
import '../../relationships/relationship_type.dart';
import '../../services/database_service.dart';

const String _createNewPersonSentinel = '__create_new_person__';

/// Opens the "Add Connection" dialog for [viewedPerson] and, if the user saves,
/// creates the connection (and, if they chose to add a brand-new person, that person
/// too) via [DatabaseService]. The relationship-type dropdown picks [viewedPerson]'s
/// own role toward the other person - e.g. choosing "Parent" saves
/// "[viewedPerson] is the parent of [other person]" - which is what keeps the
/// direction of the stored fact explicit instead of losing it (see
/// `relationship_type.dart`'s reading rule). A live sentence preview shows exactly the
/// fact that will be saved, and a non-blocking warning appears if the same fact seems
/// to already exist.
///
/// Returns `true` if a connection was saved, `false`/`null` if the dialog was
/// cancelled.
Future<bool?> showAddConnectionDialog(
  BuildContext context, {
  required Person viewedPerson,
  required List<Person> allPersons,
  required List<Connection> allConnections,
  required List<Event> allEvents,
}) {
  final otherPersons = allPersons.where((p) => p.id != viewedPerson.id).toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  return showDialog<bool>(
    context: context,
    builder: (context) => _AddConnectionDialog(
      viewedPerson: viewedPerson,
      otherPersons: otherPersons,
      allConnections: allConnections,
      events: allEvents,
    ),
  );
}

class _AddConnectionDialog extends StatefulWidget {
  final Person viewedPerson;
  final List<Person> otherPersons;
  final List<Connection> allConnections;
  final List<Event> events;

  const _AddConnectionDialog({
    required this.viewedPerson,
    required this.otherPersons,
    required this.allConnections,
    required this.events,
  });

  @override
  State<_AddConnectionDialog> createState() => _AddConnectionDialogState();
}

class _AddConnectionDialogState extends State<_AddConnectionDialog> {
  Person? _selectedPerson;
  bool _creatingNewPerson = false;
  final _newPersonNameController = TextEditingController();

  RelationshipType _type = RelationshipType.friend;
  Event? _selectedEvent;
  final _descriptionController = TextEditingController();
  DateTime _startDate = DateTime.now();
  bool _linkEvent = false;
  bool _createNewEvent = false;
  final _newEventTitleController = TextEditingController();
  bool _isSaving = false;

  @override
  void dispose() {
    _newPersonNameController.dispose();
    _descriptionController.dispose();
    _newEventTitleController.dispose();
    super.dispose();
  }

  String get _otherPersonName {
    if (_creatingNewPerson) {
      final name = _newPersonNameController.text.trim();
      return name.isEmpty ? '…' : name;
    }
    return _selectedPerson?.name ?? '…';
  }

  bool get _hasOtherPerson =>
      _creatingNewPerson ? _newPersonNameController.text.trim().isNotEmpty : _selectedPerson != null;

  bool get _isDuplicate {
    if (_creatingNewPerson || _selectedPerson == null) return false;
    return isDuplicateConnection(
      existing: widget.allConnections.map((c) => (
            person1Id: c.person1Id,
            person2Id: c.person2Id,
            relationshipType: c.relationshipType,
          )),
      person1Id: widget.viewedPerson.id,
      person2Id: _selectedPerson!.id,
      type: _type,
    );
  }

  bool get _canSave => !_isSaving && _hasOtherPerson && !_isDuplicate;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toString();
    return AlertDialog(
      title: Text(l10n.connectionDialogAddTitle),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                key: const Key('add-connection-person-dropdown'),
                decoration: InputDecoration(labelText: l10n.connectionDialogConnectWith),
                // ignore: deprecated_member_use
                value: _creatingNewPerson ? _createNewPersonSentinel : _selectedPerson?.id,
                items: [
                  ...widget.otherPersons.map(
                      (p) => DropdownMenuItem(value: p.id, child: Text(p.name))),
                  DropdownMenuItem(
                    value: _createNewPersonSentinel,
                    child: Text(l10n.connectionDialogAddNewPerson),
                  ),
                ],
                onChanged: (value) => setState(() {
                  if (value == _createNewPersonSentinel) {
                    _creatingNewPerson = true;
                    _selectedPerson = null;
                  } else {
                    _creatingNewPerson = false;
                    _selectedPerson = widget.otherPersons.firstWhere((p) => p.id == value);
                  }
                }),
              ),
              if (_creatingNewPerson) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _newPersonNameController,
                  autofocus: true,
                  decoration: InputDecoration(labelText: l10n.connectionDialogNewPersonName),
                  textCapitalization: TextCapitalization.words,
                  onChanged: (_) => setState(() {}),
                ),
              ],
              const SizedBox(height: 16),
              DropdownButtonFormField<RelationshipType>(
                key: const Key('add-connection-type-dropdown'),
                decoration: InputDecoration(
                    labelText: l10n.connectionDialogPersonIsThe(widget.viewedPerson.name)),
                // ignore: deprecated_member_use
                value: _type,
                items: RelationshipType.values
                    .map((t) =>
                        DropdownMenuItem(value: t, child: Text(RelationshipText.label(l10n, t))))
                    .toList(),
                onChanged: (t) => setState(() => _type = t ?? _type),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  RelationshipText.sentence(l10n, widget.viewedPerson.name, _otherPersonName, _type),
                  key: const Key('add-connection-sentence-preview'),
                  style: const TextStyle(fontStyle: FontStyle.italic),
                ),
              ),
              if (_isDuplicate) ...[
                const SizedBox(height: 8),
                Text(
                  l10n.connectionDialogAlreadyExists,
                  style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
                ),
              ],
              const SizedBox(height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.connectionDialogStartDate),
                subtitle: Text(DateFormat.yMMMd(locale).format(_startDate)),
                trailing: const Icon(Icons.calendar_today),
                onTap: () async {
                  final date = await showDatePicker(
                    context: context,
                    initialDate: _startDate,
                    firstDate: DateTime(1900),
                    lastDate: DateTime.now(),
                  );
                  if (date != null) setState(() => _startDate = date);
                },
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.connectionDialogLinkEvent),
                subtitle: Text(l10n.connectionDialogLinkEventSubtitle),
                value: _linkEvent,
                onChanged: (v) => setState(() {
                  _linkEvent = v;
                  if (!v) {
                    _selectedEvent = null;
                    _createNewEvent = false;
                  }
                }),
              ),
              if (_linkEvent && !_createNewEvent) ...[
                DropdownButtonFormField<Event?>(
                  decoration: InputDecoration(labelText: l10n.connectionDialogSelectEvent),
                  // ignore: deprecated_member_use
                  value: _selectedEvent,
                  items: [
                    DropdownMenuItem<Event?>(value: null, child: Text(l10n.commonNone)),
                    ...widget.events.map((e) => DropdownMenuItem(
                          value: e,
                          child: Text('${e.title} (${DateFormat.yMMMd(locale).format(e.dateTime)})'),
                        )),
                  ],
                  onChanged: (e) => setState(() => _selectedEvent = e),
                ),
                TextButton(
                  onPressed: () => setState(() => _createNewEvent = true),
                  child: Text(l10n.connectionDialogOrCreateNewEvent),
                ),
              ],
              if (_linkEvent && _createNewEvent) ...[
                TextField(
                  controller: _newEventTitleController,
                  decoration: InputDecoration(
                    labelText: l10n.connectionDialogNewEventTitle,
                    hintText: l10n.connectionDialogNewEventTitleHint,
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _createNewEvent = false),
                  child: Text(l10n.connectionDialogCancelNewEvent),
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: _descriptionController,
                decoration: InputDecoration(
                  labelText: l10n.connectionDialogDescription,
                  hintText: l10n.connectionDialogDescriptionHint,
                ),
                maxLines: 2,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: _canSave ? _save : null,
          child: _isSaving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.commonAdd),
        ),
      ],
    );
  }

  Future<void> _save() async {
    setState(() => _isSaving = true);
    final db = context.read<DatabaseService>();

    final String otherPersonId;
    if (_creatingNewPerson) {
      final newPerson = Person(name: _newPersonNameController.text.trim());
      await db.savePerson(newPerson);
      otherPersonId = newPerson.id;
    } else {
      otherPersonId = _selectedPerson!.id;
    }

    String? originEventId;
    if (_linkEvent && _createNewEvent && _newEventTitleController.text.trim().isNotEmpty) {
      final newEvent = Event(
        title: _newEventTitleController.text.trim(),
        dateTime: _startDate,
        type: EventType.social,
        participantIds: [widget.viewedPerson.id, otherPersonId],
      );
      await db.saveEvent(newEvent);
      originEventId = newEvent.id;
    } else if (_linkEvent && _selectedEvent != null) {
      originEventId = _selectedEvent!.id;
    }

    final connection = Connection(
      person1Id: widget.viewedPerson.id,
      person2Id: otherPersonId,
      relationshipType: _type.storageValue,
      originEventId: originEventId,
      description:
          _descriptionController.text.trim().isEmpty ? null : _descriptionController.text.trim(),
      startDate: _startDate,
    );
    await db.saveConnection(connection);

    if (mounted) Navigator.pop(context, true);
  }
}
