import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../../models/models.dart';
import '../../services/database_service.dart';
import '../../services/recording_file_store.dart';
import '../../widgets/recording_player.dart';
import '../map/map_tile_layer.dart';
import '../places/place_sheet.dart';
import '../persons/person_detail_screen.dart';
import 'add_event_screen.dart';

class EventDetailScreen extends StatefulWidget {
  final String eventId;

  /// Overridable for tests, so a fake store can be used instead of a real
  /// (platform-specific) one.
  final RecordingFileStore? recordingFileStore;

  const EventDetailScreen({
    super.key,
    required this.eventId,
    this.recordingFileStore,
  });

  @override
  State<EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends State<EventDetailScreen> {
  int _refreshKey = 0;
  late final RecordingFileStore _recordingFileStore =
      widget.recordingFileStore ?? createRecordingFileStore();

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
                    // Respects the story's datePrecision - old stories often
                    // only know a year or month, and showing a fabricated
                    // time of day would misrepresent that.
                    Text(event.displayDate),
                    if (event.endDateTime != null)
                      Text(
                          'End: ${formatDateWithPrecision(event.endDateTime!, event.datePrecision)}'),
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
                    trailing: person != null ? const Icon(Icons.chevron_right) : null,
                    onTap: person == null
                        ? null
                        : () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => PersonDetailScreen(personId: person.id)),
                            ),
                  ),
                );
              },
            )),
      ],
    );
  }

  Widget _buildFilesSection(Event event) {
    final recordings = event.files.where((f) => f.isRecording).toList();
    final otherFiles = event.files.where((f) => !f.isRecording).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (recordings.isNotEmpty) ...[
          const Text('Recordings',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          ...recordings.map((file) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: RecordingPlayer(file: file, store: _recordingFileStore),
              )),
          const SizedBox(height: 8),
        ],
        if (otherFiles.isNotEmpty) ...[
          const Text('Files',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          ...otherFiles.map((file) => Card(
                child: ListTile(
                  leading: Icon(file.isImage
                      ? Icons.image
                      : (file.isAudio ? Icons.audiotrack : Icons.attach_file)),
                  title: Text(file.fileName),
                  subtitle: Text('${(file.size / 1024).toStringAsFixed(1)} KB'),
                ),
              )),
        ],
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
              child: InkWell(
                onTap: () => PlaceSheet.show(context, placeId: place.id),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.place),
                      title: Text(place.name),
                      subtitle: place.address != null ? Text(place.address!) : null,
                      trailing: const Icon(Icons.chevron_right),
                    ),
                    SizedBox(
                      height: 100,
                      child: IgnorePointer(
                        child: ClipRRect(
                          borderRadius:
                              const BorderRadius.vertical(bottom: Radius.circular(12)),
                          child: FlutterMap(
                            options: MapOptions(
                              initialCenter: LatLng(place.latitude, place.longitude),
                              initialZoom: 14,
                              interactionOptions:
                                  const InteractionOptions(flags: InteractiveFlag.none),
                            ),
                            children: [
                              const StoryMapTileLayer(),
                              MarkerLayer(markers: [
                                Marker(
                                  point: LatLng(place.latitude, place.longitude),
                                  width: 32,
                                  height: 32,
                                  alignment: Alignment.topCenter,
                                  child: const Icon(Icons.location_pin,
                                      color: Colors.red, size: 32),
                                ),
                              ]),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
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

  /// Deleting a story only ever soft-deletes the Event itself; what
  /// happens to a recording it owns needs an explicit choice from the user
  /// per RecordingFileStore's deletion rule (see its doc comment): keeping
  /// it recoverable for as long as the soft-deleted story could still be
  /// restored, or permanently deleting it right now if that's what they
  /// actually want.
  void _deleteEvent(BuildContext context, DatabaseService db, Event event) {
    final recordings = event.files.where((f) => f.isRecording).toList();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Story'),
        content: Text(recordings.isEmpty
            ? 'Are you sure you want to delete "${event.title}"?'
            : 'Are you sure you want to delete "${event.title}"? '
                'Its recording can be kept (in case you want to restore this '
                'story later) or permanently deleted now.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          if (recordings.isNotEmpty)
            TextButton(
              onPressed: () async {
                await db.deleteEvent(event.id);
                for (final recording in recordings) {
                  await db.deleteRecordingPermanently(recording.id, _recordingFileStore);
                }
                if (context.mounted) {
                  Navigator.pop(context);
                  Navigator.pop(context);
                }
              },
              child: const Text('Delete story + recording', style: TextStyle(color: Colors.red)),
            ),
          TextButton(
            onPressed: () async {
              await db.deleteEvent(event.id);
              if (context.mounted) {
                Navigator.pop(context);
                Navigator.pop(context);
              }
            },
            child: Text(recordings.isEmpty ? 'Delete' : 'Delete story, keep recording',
                style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
