import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/models.dart';
import '../../relationships/family_graph.dart';
import '../../relationships/relationship_text.dart';
import '../../services/database_service.dart';
import '../events/event_detail_screen.dart';
import 'add_connection_dialog.dart';
import 'add_person_screen.dart';
import 'edit_connection_dialog.dart';
import 'relationship_graph_screen.dart';

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
                    icon: const Icon(Icons.account_tree_outlined),
                    tooltip: 'Show family graph',
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => RelationshipGraphScreen(centerPersonId: person.id),
                      ),
                    ),
                  ),
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
    return FutureBuilder<List<Object>>(
      future: Future.wait([db.getPersons(), db.getConnections()]),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();
        final allPersons = snapshot.data![0] as List<Person>;
        final allConnections = snapshot.data![1] as List<Connection>;
        final graph = FamilyGraph.build(persons: allPersons, connections: allConnections);
        final grouped = graph.groupedNeighbors(person.id);
        final nonEmptyGroups =
            RelationshipGroup.values.where((g) => grouped[g]!.isNotEmpty).toList();

        if (nonEmptyGroups.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Connections',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            for (final group in nonEmptyGroups) ...[
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 4),
                child: Text(
                  RelationshipText.groupLabel(group),
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
              ...grouped[group]!.map(
                  (entry) => _buildConnectionTile(context, db, person, entry, graph)),
            ],
          ],
        );
      },
    );
  }

  Widget _buildConnectionTile(BuildContext context, DatabaseService db,
      Person person, PersonRelationshipView entry, FamilyGraph graph) {
    final neighbor = graph.personById(entry.neighborId);
    final neighborName = neighbor?.name ?? 'Unknown';
    final roleLabel = entry.kind.isKnown
        ? RelationshipText.roleOfLabel(entry.kind.known!, neighborName)
        : RelationshipText.roleOfLabelForRaw(entry.kind.raw, neighborName);

    return ListTile(
      leading: CircleAvatar(
        child: Text(neighborName.isNotEmpty ? neighborName[0].toUpperCase() : '?'),
      ),
      title: Text(neighborName),
      subtitle: Text(entry.isDerived ? '$roleLabel · derived' : roleLabel),
      trailing: entry.isDerived
          ? Tooltip(
              message: 'Derived from shared parents - not an editable connection',
              child: Icon(Icons.auto_awesome,
                  size: 20, color: Theme.of(context).colorScheme.outline),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  onPressed: neighbor == null
                      ? null
                      : () => _editConnection(context, db, person, entry, neighbor),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () => _deleteConnection(context, db, entry),
                ),
              ],
            ),
      onTap: neighbor != null
          ? () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => PersonDetailScreen(personId: neighbor.id),
                ),
              )
          : null,
    );
  }

  void _editConnection(BuildContext context, DatabaseService db, Person person,
      PersonRelationshipView entry, Person neighbor) async {
    final connection = await db.getConnection(entry.edgeId);
    if (connection == null || !context.mounted) return;
    final saved = await showEditConnectionDialog(
      context,
      connection: connection,
      viewedPerson: person,
      otherPerson: neighbor,
    );
    if (saved == true && mounted) setState(() => _refreshKey++);
  }

  void _deleteConnection(
      BuildContext context, DatabaseService db, PersonRelationshipView entry) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Connection'),
        content: const Text('Are you sure you want to delete this connection?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              await db.deleteConnection(entry.edgeId);
              if (dialogContext.mounted) Navigator.pop(dialogContext);
              if (mounted) setState(() => _refreshKey++);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
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
    final allPersons = await db.getPersons();
    final allConnections = await db.getConnections();
    final allEvents = await db.getEvents();

    if (!context.mounted) return;

    final saved = await showAddConnectionDialog(
      context,
      viewedPerson: person,
      allPersons: allPersons,
      allConnections: allConnections,
      allEvents: allEvents,
    );

    if (saved == true && mounted) setState(() => _refreshKey++);
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
