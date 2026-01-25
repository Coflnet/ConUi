import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../models/models.dart';
import '../../services/database_service.dart';

class AddEventScreen extends StatefulWidget {
  final Event? existingEvent; // If provided, we're editing an existing event

  const AddEventScreen({super.key, this.existingEvent});

  @override
  State<AddEventScreen> createState() => _AddEventScreenState();
}

class _AddEventScreenState extends State<AddEventScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  EventType _type = EventType.other;
  DateTime _dateTime = DateTime.now();
  DateTime? _endDateTime;
  List<String> _participantIds = [];
  String? _placeId;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    if (widget.existingEvent != null) {
      final e = widget.existingEvent!;
      _titleController.text = e.title;
      _descriptionController.text = e.description ?? '';
      _type = e.type;
      _dateTime = e.dateTime;
      _endDateTime = e.endDateTime;
      _participantIds = List.from(e.participantIds);
      _placeId = e.placeId;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _selectDateTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _dateTime,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date == null) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_dateTime),
    );
    if (time == null) return;

    setState(() {
      _dateTime =
          DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);

    final db = context.read<DatabaseService>();
    final event = widget.existingEvent != null
        ? widget.existingEvent!.copyWith(
            title: _titleController.text.trim(),
            description: _descriptionController.text.trim().isEmpty
                ? null
                : _descriptionController.text.trim(),
            type: _type,
            dateTime: _dateTime,
            endDateTime: _endDateTime,
            participantIds: _participantIds,
            placeId: _placeId,
          )
        : Event(
            title: _titleController.text.trim(),
            description: _descriptionController.text.trim().isEmpty
                ? null
                : _descriptionController.text.trim(),
            type: _type,
            dateTime: _dateTime,
            endDateTime: _endDateTime,
            participantIds: _participantIds,
            placeId: _placeId,
          );

    await db.saveEvent(event);

    if (mounted) {
      Navigator.pop(
          context, true); // Return true to indicate save was successful
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                'Event "${event.title}" ${widget.existingEvent != null ? 'updated' : 'created'}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existingEvent != null ? 'Edit Event' : 'Add Event'),
        actions: [
          TextButton(
            onPressed: _isSaving ? null : _save,
            child: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _titleController,
              decoration: const InputDecoration(
                  labelText: 'Title *', prefixIcon: Icon(Icons.title)),
              validator: (v) =>
                  v == null || v.trim().isEmpty ? 'Title required' : null,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<EventType>(
              value: _type,
              decoration: const InputDecoration(
                  labelText: 'Type', prefixIcon: Icon(Icons.category)),
              items: EventType.values
                  .map((t) => DropdownMenuItem(value: t, child: Text(t.name)))
                  .toList(),
              onChanged: (v) => setState(() => _type = v ?? EventType.other),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.schedule),
              title: Text(DateFormat.yMMMd().add_jm().format(_dateTime)),
              subtitle: const Text('Start time - Tap to change'),
              onTap: _selectDateTime,
            ),
            ListTile(
              leading: const Icon(Icons.schedule_outlined),
              title: Text(_endDateTime != null
                  ? DateFormat.yMMMd().add_jm().format(_endDateTime!)
                  : 'No end time'),
              subtitle: const Text('End time (optional) - Tap to change'),
              trailing: _endDateTime != null
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(() => _endDateTime = null))
                  : null,
              onTap: _selectEndDateTime,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _descriptionController,
              decoration: const InputDecoration(
                  labelText: 'Description', prefixIcon: Icon(Icons.note)),
              maxLines: 3,
            ),
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: const Icon(Icons.people),
                title: Text(_participantIds.isEmpty
                    ? 'Add participants'
                    : '${_participantIds.length} participants'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _selectParticipants(),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.place),
                title: Text(
                    _placeId == null ? 'Add location' : 'Location selected'),
                trailing: _placeId != null
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(() => _placeId = null))
                    : const Icon(Icons.chevron_right),
                onTap: () => _selectPlace(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _selectEndDateTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _endDateTime ?? _dateTime,
      firstDate: _dateTime,
      lastDate: DateTime(2100),
    );
    if (date == null) return;

    final time = await showTimePicker(
      context: context,
      initialTime: _endDateTime != null
          ? TimeOfDay.fromDateTime(_endDateTime!)
          : TimeOfDay.fromDateTime(_dateTime.add(const Duration(hours: 1))),
    );
    if (time == null) return;

    setState(() {
      _endDateTime =
          DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  void _selectParticipants() async {
    final db = context.read<DatabaseService>();
    final persons = await db.getPersons();

    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Participants'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: persons
                .map((p) => CheckboxListTile(
                      title: Text(p.name),
                      value: _participantIds.contains(p.id),
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            _participantIds.add(p.id);
                          } else {
                            _participantIds.remove(p.id);
                          }
                        });
                        Navigator.pop(context);
                      },
                    ))
                .toList(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'))
        ],
      ),
    );
    setState(() {});
  }

  void _selectPlace() async {
    final db = context.read<DatabaseService>();
    final places = await db.getPlaces();

    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Place'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: places
                .map((p) => ListTile(
                      title: Text(p.name),
                      subtitle: p.address != null ? Text(p.address!) : null,
                      onTap: () {
                        setState(() => _placeId = p.id);
                        Navigator.pop(context);
                      },
                    ))
                .toList(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'))
        ],
      ),
    );
  }
}
