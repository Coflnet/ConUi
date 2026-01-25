import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../models/models.dart';
import '../../services/database_service.dart';
import 'add_event_screen.dart';

class EventDetailScreen extends StatefulWidget {
  final String eventId;

  const EventDetailScreen({super.key, required this.eventId});

  @override
  State<EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends State<EventDetailScreen> {
  int _refreshKey = 0;

  void _refresh() {
    setState(() => _refreshKey++);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<DatabaseService>(
      builder: (context, db, _) {
        return FutureBuilder<Event?>(
          key: ValueKey(_refreshKey),
          future: db.getEvent(widget.eventId),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return Scaffold(
                appBar: AppBar(title: const Text('Loading...')),
                body: const Center(child: CircularProgressIndicator()),
              );
            }

            final event = snapshot.data;
            if (event == null) {
              return Scaffold(
                appBar: AppBar(title: const Text('Not Found')),
                body: const Center(child: Text('Event not found')),
              );
            }

            return Scaffold(
              appBar: AppBar(
                title: Text(event.title),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.edit),
                    onPressed: () => _editEvent(context, event),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete),
                    onPressed: () => _deleteEvent(context, db, event),
                  ),
                ],
              ),
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildInfoCard(event),
                    const SizedBox(height: 16),
                    if (event.description != null) ...[
                      _buildSection('Description', event.description!),
                      const SizedBox(height: 16),
                    ],
                    if (event.participantIds.isNotEmpty)
                      _buildParticipantsSection(context, db, event),
                    if (event.placeId != null)
                      _buildPlaceSection(context, db, event),
                    if (event.files.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _buildFilesSection(event),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildInfoCard(Event event) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                const Icon(Icons.schedule),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        'Start: ${DateFormat.yMMMd().add_jm().format(event.dateTime)}'),
                    if (event.endDateTime != null)
                      Text(
                          'End: ${DateFormat.yMMMd().add_jm().format(event.endDateTime!)}'),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.category),
                const SizedBox(width: 8),
                Text(event.type.name),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(String title, String content) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        Text(content),
      ],
    );
  }

  Widget _buildParticipantsSection(
      BuildContext context, DatabaseService db, Event event) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Participants',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        ...event.participantIds.map((id) => FutureBuilder<Person?>(
              future: db.getPerson(id),
              builder: (context, snapshot) {
                final person = snapshot.data;
                return Card(
                  child: ListTile(
                    leading: CircleAvatar(child: Text(person?.name[0] ?? '?')),
                    title: Text(person?.name ?? 'Unknown'),
                  ),
                );
              },
            )),
      ],
    );
  }

  Widget _buildFilesSection(Event event) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Files',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        ...event.files.map((file) => Card(
              child: ListTile(
                leading: Icon(file.isImage
                    ? Icons.image
                    : (file.isAudio ? Icons.audiotrack : Icons.attach_file)),
                title: Text(file.fileName),
                subtitle: Text('${(file.size / 1024).toStringAsFixed(1)} KB'),
              ),
            )),
      ],
    );
  }

  Widget _buildPlaceSection(
      BuildContext context, DatabaseService db, Event event) {
    return FutureBuilder<Place?>(
      future: db.getPlace(event.placeId!),
      builder: (context, snapshot) {
        final place = snapshot.data;
        if (place == null) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 16),
            const Text('Location',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.place),
                title: Text(place.name),
                subtitle: place.address != null ? Text(place.address!) : null,
              ),
            ),
          ],
        );
      },
    );
  }

  void _editEvent(BuildContext context, Event event) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AddEventScreen(existingEvent: event),
      ),
    );
    if (result == true) {
      _refresh();
    }
  }

  void _deleteEvent(BuildContext context, DatabaseService db, Event event) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Event'),
        content: Text('Are you sure you want to delete "${event.title}"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              await db.deleteEvent(event.id);
              if (context.mounted) {
                Navigator.pop(context);
                Navigator.pop(context);
              }
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
