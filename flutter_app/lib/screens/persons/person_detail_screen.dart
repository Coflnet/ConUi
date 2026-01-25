import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../models/models.dart';
import '../../services/database_service.dart';
import '../events/event_detail_screen.dart';
import 'add_person_screen.dart';

class PersonDetailScreen extends StatefulWidget {
  final String personId;

  const PersonDetailScreen({super.key, required this.personId});

  @override
  State<PersonDetailScreen> createState() => _PersonDetailScreenState();
}

class _PersonDetailScreenState extends State<PersonDetailScreen> {
  int _refreshKey = 0;

  @override
  Widget build(BuildContext context) {
    return Consumer<DatabaseService>(
      builder: (context, db, _) {
        return FutureBuilder<Person?>(
          key: ValueKey(_refreshKey),
          future: db.getPerson(widget.personId),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return Scaffold(
                appBar: AppBar(title: const Text('Loading...')),
                body: const Center(child: CircularProgressIndicator()),
              );
            }

            final person = snapshot.data;
            if (person == null) {
              return Scaffold(
                appBar: AppBar(title: const Text('Not Found')),
                body: const Center(child: Text('Person not found')),
              );
            }

            return Scaffold(
              appBar: AppBar(
                title: Text(person.name),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.edit),
                    onPressed: () => _editPerson(context, person),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete),
                    onPressed: () => _deletePerson(context, db, person),
                  ),
                ],
              ),
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeader(context, person),
                    const SizedBox(height: 24),
                    if (person.aliases.isNotEmpty) ...[
                      _buildSection('Aliases', person.aliases.join(', ')),
                      const SizedBox(height: 16),
                    ],
                    if (person.email != null)
                      _buildInfoTile(Icons.email, 'Email', person.email!),
                    if (person.phoneNumber != null)
                      _buildInfoTile(Icons.phone, 'Phone', person.phoneNumber!),
                    if (person.birthday != null)
                      _buildInfoTile(Icons.cake, 'Birthday',
                          _formatDate(person.birthday!)),
                    if (person.company != null)
                      _buildInfoTile(
                          Icons.business, 'Company', person.company!),
                    if (person.jobTitle != null)
                      _buildInfoTile(Icons.work, 'Job Title', person.jobTitle!),
                    if (person.address != null)
                      _buildInfoTile(
                          Icons.location_on, 'Address', person.address!),
                    if (person.notes != null) ...[
                      const SizedBox(height: 24),
                      _buildSection('Notes', person.notes!),
                    ],
                    if (person.customAttributes.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      _buildCustomAttributes(person.customAttributes),
                    ],
                    const SizedBox(height: 24),
                    _buildConnectionsSection(context, db, person),
                    const SizedBox(height: 24),
                    _buildEventsSection(context, db, person),
                  ],
                ),
              ),
              floatingActionButton: FloatingActionButton.extended(
                onPressed: () => _addConnection(context, db, person),
                icon: const Icon(Icons.link),
                label: const Text('Add Connection'),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, Person person) {
    return Row(
      children: [
        CircleAvatar(
          radius: 40,
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Text(
            person.name.isNotEmpty ? person.name[0].toUpperCase() : '?',
            style: TextStyle(
              fontSize: 32,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                person.name,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              if (person.company != null || person.jobTitle != null)
                Text(
                  [person.jobTitle, person.company]
                      .where((e) => e != null)
                      .join(' at '),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.grey,
                      ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSection(String title, String content) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 8),
        Text(content),
      ],
    );
  }

  Widget _buildInfoTile(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.grey),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              Text(value),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCustomAttributes(Map<String, String> attributes) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Custom Attributes',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        const SizedBox(height: 8),
        ...attributes.entries.map((e) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Text('${e.key}: ',
                      style: const TextStyle(fontWeight: FontWeight.w500)),
                  Text(e.value),
                ],
              ),
            )),
      ],
    );
  }

  Widget _buildConnectionsSection(
      BuildContext context, DatabaseService db, Person person) {
    return FutureBuilder<List<Connection>>(
      future: db.getConnectionsForPerson(person.id),
      builder: (context, snapshot) {
        final connections = snapshot.data ?? [];
        if (connections.isEmpty) {
          return const SizedBox.shrink();
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Connections',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            ...connections
                .map((conn) => _buildConnectionTile(context, db, person, conn)),
          ],
        );
      },
    );
  }

  Widget _buildConnectionTile(BuildContext context, DatabaseService db,
      Person person, Connection conn) {
    final otherPersonId =
        conn.person1Id == person.id ? conn.person2Id : conn.person1Id;

    return FutureBuilder<Person?>(
      future: db.getPerson(otherPersonId),
      builder: (context, snapshot) {
        final otherPerson = snapshot.data;
        return ListTile(
          leading: CircleAvatar(
            child: Text(otherPerson?.name.isNotEmpty == true
                ? otherPerson!.name[0].toUpperCase()
                : '?'),
          ),
          title: Text(otherPerson?.name ?? 'Unknown'),
          subtitle: Text(conn.relationshipType),
          onTap: otherPerson != null
              ? () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          PersonDetailScreen(personId: otherPerson.id),
                    ),
                  )
              : null,
        );
      },
    );
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year}';
  }

  void _editPerson(BuildContext context, Person person) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AddPersonScreen(existingPerson: person),
      ),
    );
    setState(() => _refreshKey++);
  }

  void _deletePerson(BuildContext context, DatabaseService db, Person person) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Person'),
        content: Text('Are you sure you want to delete ${person.name}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              await db.deletePerson(person.id);
              if (context.mounted) {
                Navigator.pop(context); // Close dialog
                Navigator.pop(context); // Go back to list
              }
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _addConnection(
      BuildContext context, DatabaseService db, Person person) async {
    // Get all persons except current person
    final allPersons = await db.getPersons();
    final otherPersons = allPersons.where((p) => p.id != person.id).toList();

    if (otherPersons.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Add another person first to create a connection')),
        );
      }
      return;
    }

    // Get all events for selecting origin event
    final allEvents = await db.getEvents();

    if (!context.mounted) return;

    final result = await showDialog<Connection>(
      context: context,
      builder: (context) => _AddConnectionDialog(
        currentPerson: person,
        otherPersons: otherPersons,
        events: allEvents,
      ),
    );

    if (result != null) {
      await db.saveConnection(result);
      setState(() => _refreshKey++);
    }
  }

  Widget _buildEventsSection(
      BuildContext context, DatabaseService db, Person person) {
    return FutureBuilder<List<Event>>(
      future: db.getEvents(),
      builder: (context, snapshot) {
        final allEvents = snapshot.data ?? [];
        final personEvents = allEvents
            .where((e) => e.participantIds.contains(person.id))
            .toList();
        personEvents.sort((a, b) => b.dateTime.compareTo(a.dateTime));

        if (personEvents.isEmpty) {
          return const SizedBox.shrink();
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Events',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            ...personEvents.take(5).map((event) => ListTile(
                  leading: const Icon(Icons.event),
                  title: Text(event.title),
                  subtitle: Text(
                      '${_formatDate(event.dateTime)} • ${event.type.name}'),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => EventDetailScreen(eventId: event.id),
                    ),
                  ),
                )),
            if (personEvents.length > 5)
              TextButton(
                onPressed: () {
                  // TODO: Navigate to full events list filtered by person
                },
                child: Text('See all ${personEvents.length} events'),
              ),
          ],
        );
      },
    );
  }
}

// Dialog for adding a connection
class _AddConnectionDialog extends StatefulWidget {
  final Person currentPerson;
  final List<Person> otherPersons;
  final List<Event> events;

  const _AddConnectionDialog({
    required this.currentPerson,
    required this.otherPersons,
    required this.events,
  });

  @override
  State<_AddConnectionDialog> createState() => _AddConnectionDialogState();
}

class _AddConnectionDialogState extends State<_AddConnectionDialog> {
  Person? _selectedPerson;
  Event? _selectedEvent;
  String _relationshipType = 'friend';
  final _descriptionController = TextEditingController();
  DateTime _startDate = DateTime.now();
  bool _createNewEvent = false;
  final _newEventTitleController = TextEditingController();

  final List<String> _relationshipTypes = [
    'friend',
    'colleague',
    'family',
    'partner',
    'spouse',
    'parent',
    'child',
    'sibling',
    'acquaintance',
    'mentor',
    'other',
  ];

  @override
  void dispose() {
    _descriptionController.dispose();
    _newEventTitleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Connection'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Select person
              DropdownButtonFormField<Person>(
                decoration: const InputDecoration(labelText: 'Connect with *'),
                value: _selectedPerson,
                items: widget.otherPersons
                    .map((p) => DropdownMenuItem(
                          value: p,
                          child: Text(p.name),
                        ))
                    .toList(),
                onChanged: (p) => setState(() => _selectedPerson = p),
              ),
              const SizedBox(height: 16),

              // Relationship type
              DropdownButtonFormField<String>(
                decoration:
                    const InputDecoration(labelText: 'Relationship Type'),
                value: _relationshipType,
                items: _relationshipTypes
                    .map((t) => DropdownMenuItem(
                          value: t,
                          child: Text(t[0].toUpperCase() + t.substring(1)),
                        ))
                    .toList(),
                onChanged: (t) =>
                    setState(() => _relationshipType = t ?? 'friend'),
              ),
              const SizedBox(height: 16),

              // Start date
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
                  if (date != null) {
                    setState(() => _startDate = date);
                  }
                },
              ),
              const SizedBox(height: 16),

              // Origin event toggle
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Link to Origin Event'),
                subtitle: const Text(
                    'Optional: the event that started this connection'),
                value: !_createNewEvent && _selectedEvent != null ||
                    _createNewEvent,
                onChanged: (v) => setState(() {
                  if (!v) {
                    _selectedEvent = null;
                    _createNewEvent = false;
                  }
                }),
              ),

              if (!_createNewEvent &&
                  (_selectedEvent != null || widget.events.isNotEmpty)) ...[
                // Select existing event
                DropdownButtonFormField<Event?>(
                  decoration: const InputDecoration(labelText: 'Select Event'),
                  value: _selectedEvent,
                  items: [
                    const DropdownMenuItem<Event?>(
                      value: null,
                      child: Text('None'),
                    ),
                    ...widget.events.map((e) => DropdownMenuItem(
                          value: e,
                          child: Text(
                              '${e.title} (${DateFormat.yMMMd().format(e.dateTime)})'),
                        )),
                  ],
                  onChanged: (e) => setState(() => _selectedEvent = e),
                ),
                TextButton(
                  onPressed: () => setState(() => _createNewEvent = true),
                  child: const Text('Or create new event'),
                ),
              ],

              if (_createNewEvent) ...[
                TextField(
                  controller: _newEventTitleController,
                  decoration: const InputDecoration(
                    labelText: 'New Event Title',
                    hintText: 'e.g., First met at conference',
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _createNewEvent = false),
                  child: const Text('Cancel new event'),
                ),
              ],

              const SizedBox(height: 16),
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
          onPressed: _selectedPerson == null
              ? null
              : () async {
                  String? originEventId;

                  // Create new event if specified
                  if (_createNewEvent &&
                      _newEventTitleController.text.isNotEmpty) {
                    final db = context.read<DatabaseService>();
                    final newEvent = Event(
                      title: _newEventTitleController.text.trim(),
                      dateTime: _startDate,
                      type: EventType.social,
                      participantIds: [
                        widget.currentPerson.id,
                        _selectedPerson!.id
                      ],
                    );
                    await db.saveEvent(newEvent);
                    originEventId = newEvent.id;
                  } else if (_selectedEvent != null) {
                    originEventId = _selectedEvent!.id;
                  }

                  final connection = Connection(
                    person1Id: widget.currentPerson.id,
                    person2Id: _selectedPerson!.id,
                    relationshipType: _relationshipType,
                    originEventId: originEventId,
                    description: _descriptionController.text.trim().isEmpty
                        ? null
                        : _descriptionController.text.trim(),
                    startDate: _startDate,
                  );

                  if (context.mounted) {
                    Navigator.pop(context, connection);
                  }
                },
          child: const Text('Add'),
        ),
      ],
    );
  }
}
