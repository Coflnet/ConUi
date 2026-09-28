import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../relationships/relationship_text.dart';
import '../../relationships/relationship_type.dart';
import '../../services/database_service.dart';

/// Opens the "Edit Connection" dialog for [connection], viewed from [viewedPerson]'s
/// side (the type dropdown - and a "Swap direction" shortcut for directed types - edit
/// [viewedPerson]'s own role toward [otherPerson], exactly like the add dialog). A
/// connection whose stored type predates the typed vocabulary (see [RelationshipKind])
/// shows its current raw value and starts the dropdown on "Other"; saving migrates it
/// to the chosen known type.
///
/// Saves via [DatabaseService.saveConnection] and returns `true`, or `false`/`null` if
/// cancelled.
Future<bool?> showEditConnectionDialog(
  BuildContext context, {
  required Connection connection,
  required Person viewedPerson,
  required Person otherPerson,
}) {
  return showDialog<bool>(
    context: context,
    builder: (context) => _EditConnectionDialog(
      connection: connection,
      viewedPerson: viewedPerson,
      otherPerson: otherPerson,
    ),
  );
}

class _EditConnectionDialog extends StatefulWidget {
  final Connection connection;
  final Person viewedPerson;
  final Person otherPerson;

  const _EditConnectionDialog({
    required this.connection,
    required this.viewedPerson,
    required this.otherPerson,
  });

  @override
  State<_EditConnectionDialog> createState() => _EditConnectionDialogState();
}

class _EditConnectionDialogState extends State<_EditConnectionDialog> {
  late RelationshipKind _originalKind;
  late RelationshipType _type;
  late DateTime _startDate;
  DateTime? _endDate;
  late final TextEditingController _descriptionController;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _originalKind = relationshipKindFrom(
      person1Id: widget.connection.person1Id,
      person2Id: widget.connection.person2Id,
      relationshipType: widget.connection.relationshipType,
      viewerPersonId: widget.viewedPerson.id,
    );
    _type = _originalKind.known ?? RelationshipType.other;
    _startDate = widget.connection.startDate;
    _endDate = widget.connection.endDate;
    _descriptionController = TextEditingController(text: widget.connection.description ?? '');
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Connection'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('With ${widget.otherPerson.name}',
                  style: Theme.of(context).textTheme.titleMedium),
              if (!_originalKind.isKnown) ...[
                const SizedBox(height: 4),
                Text(
                  'Currently stored as "${RelationshipText.labelForRaw(_originalKind.raw)}" - pick a type below to migrate it.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<RelationshipType>(
                      decoration:
                          InputDecoration(labelText: '${widget.viewedPerson.name} is the ...'),
                      // ignore: deprecated_member_use
                      value: _type,
                      items: RelationshipType.values
                          .map((t) =>
                              DropdownMenuItem(value: t, child: Text(RelationshipText.label(t))))
                          .toList(),
                      onChanged: (t) => setState(() => _type = t ?? _type),
                    ),
                  ),
                  if (_type.isDirected)
                    IconButton(
                      tooltip: 'Swap direction',
                      icon: const Icon(Icons.swap_vert),
                      onPressed: () => setState(() => _type = inverseOf(_type)),
                    ),
                ],
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
                  RelationshipText.sentence(widget.viewedPerson.name, widget.otherPerson.name, _type),
                  style: const TextStyle(fontStyle: FontStyle.italic),
                ),
              ),
              const SizedBox(height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Start Date'),
                subtitle: Text(DateFormat.yMMMd().format(_startDate)),
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
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('End Date'),
                subtitle: Text(_endDate == null ? 'None (ongoing)' : DateFormat.yMMMd().format(_endDate!)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_endDate != null)
                      IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(() => _endDate = null),
                      ),
                    const Icon(Icons.calendar_today),
                  ],
                ),
                onTap: () async {
                  final date = await showDatePicker(
                    context: context,
                    initialDate: _endDate ?? DateTime.now(),
                    firstDate: DateTime(1900),
                    lastDate: DateTime(2100),
                  );
                  if (date != null) setState(() => _endDate = date);
                },
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  hintText: 'Optional notes about this connection',
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
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isSaving ? null : _save,
          child: _isSaving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    setState(() => _isSaving = true);
    final db = context.read<DatabaseService>();

    // The dropdown edits the *viewed* person's own role; convert back to the stored
    // "person1 is the <type> of person2" form depending on which side they are.
    final storageType = widget.viewedPerson.id == widget.connection.person1Id
        ? _type.storageValue
        : inverseOf(_type).storageValue;

    final updated = Connection(
      id: widget.connection.id,
      person1Id: widget.connection.person1Id,
      person2Id: widget.connection.person2Id,
      relationshipType: storageType,
      originEventId: widget.connection.originEventId,
      description:
          _descriptionController.text.trim().isEmpty ? null : _descriptionController.text.trim(),
      startDate: _startDate,
      endDate: _endDate,
      createdAt: widget.connection.createdAt,
      updatedAt: DateTime.now(),
    );
    await db.saveConnection(updated);

    if (mounted) Navigator.pop(context, true);
  }
}
