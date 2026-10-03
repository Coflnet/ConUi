import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../models/models.dart';
import '../../services/database_service.dart';
import '../../services/recording_file_store.dart';
import '../../widgets/recording_player.dart';
import '../events/event_detail_screen.dart';
import '../map/location_picker_screen.dart';
import '../map/map_tile_layer.dart';
import '../persons/person_detail_screen.dart';
import '../quick_add/quick_add_sheet.dart';

/// The place sheet: a place's editable name, its position on a small map
/// (tap to adjust via the shared [LocationPickerScreen]), every story that
/// happened there in date order with its persons and a player for its
/// recording, and "Add story here".
class PlaceSheet extends StatefulWidget {
  final String placeId;

  const PlaceSheet({super.key, required this.placeId});

  static Future<void> show(BuildContext context, {required String placeId}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => PlaceSheet(placeId: placeId),
    );
  }

  @override
  State<PlaceSheet> createState() => PlaceSheetState();
}

class PlaceSheetState extends State<PlaceSheet> {
  int _refreshKey = 0;
  late final RecordingFileStore _recordingFileStore = createRecordingFileStore();
  late final TextEditingController _nameController = TextEditingController();
  String? _nameEditedFor;

  void _refresh() => setState(() => _refreshKey++);

  Future<void> _renamePlace(DatabaseService db, Place place, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed == place.name) return;
    await db.savePlace(place.copyWith(name: trimmed));
    _refresh();
  }

  Future<void> _adjustPosition(DatabaseService db, Place place) async {
    final newPosition = await Navigator.push<LatLng>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            LocationPickerScreen(initialPosition: LatLng(place.latitude, place.longitude)),
      ),
    );
    if (newPosition == null) return;
    await db.savePlace(
        place.copyWith(latitude: newPosition.latitude, longitude: newPosition.longitude));
    _refresh();
  }

  Future<void> _addStoryHere(Place place) async {
    final notifier = ValueNotifier<LatLng>(LatLng(place.latitude, place.longitude));
    final result =
        await QuickAddSheet.show(context, position: notifier, initialPlace: place);
    notifier.dispose();
    if (result != null) _refresh();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<DatabaseService>(
      builder: (context, db, _) {
        return FutureBuilder<List<Object?>>(
          key: ValueKey(_refreshKey),
          future: Future.wait([db.getPlace(widget.placeId), db.getEvents(), db.getPersons()]),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const SizedBox(
                  height: 200, child: Center(child: CircularProgressIndicator()));
            }
            final l10n = AppLocalizations.of(context);
            final place = snapshot.data![0] as Place?;
            if (place == null) {
              return SizedBox(
                  height: 120, child: Center(child: Text(l10n.placeSheetNotFound)));
            }
            final allEvents = snapshot.data![1] as List<Event>;
            final allPersons = snapshot.data![2] as List<Person>;
            final stories = allEvents.where((e) => e.placeId == place.id).toList()
              ..sort(Event.compareByDate);

            if (_nameEditedFor != place.id) {
              _nameController.text = place.name;
              _nameEditedFor = place.id;
            }

            return DraggableScrollableSheet(
              initialChildSize: 0.75,
              minChildSize: 0.4,
              maxChildSize: 0.95,
              expand: false,
              builder: (context, scrollController) => SafeArea(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.all(16),
                  children: [
                    TextField(
                      controller: _nameController,
                      style: Theme.of(context).textTheme.headlineSmall,
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.check),
                          tooltip: l10n.placeSheetEditName,
                          onPressed: () => _renamePlace(db, place, _nameController.text),
                        ),
                      ),
                      onSubmitted: (value) => _renamePlace(db, place, value),
                    ),
                    const SizedBox(height: 8),
                    GestureDetector(
                      onTap: () => _adjustPosition(db, place),
                      child: Stack(
                        children: [
                          SizedBox(
                            height: 140,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: FlutterMap(
                                options: MapOptions(
                                  initialCenter: LatLng(place.latitude, place.longitude),
                                  initialZoom: 15,
                                  interactionOptions:
                                      const InteractionOptions(flags: InteractiveFlag.none),
                                ),
                                children: [
                                  const StoryMapTileLayer(),
                                  MarkerLayer(markers: [
                                    Marker(
                                      point: LatLng(place.latitude, place.longitude),
                                      width: 40,
                                      height: 40,
                                      alignment: Alignment.topCenter,
                                      child: const Icon(Icons.location_pin,
                                          color: Colors.red, size: 40),
                                    ),
                                  ]),
                                ],
                              ),
                            ),
                          ),
                          Positioned(
                            right: 8,
                            bottom: 24,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(l10n.placeSheetAdjustPosition,
                                  style: Theme.of(context).textTheme.bodySmall),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: () => _addStoryHere(place),
                      icon: const Icon(Icons.add),
                      label: Text(l10n.placeSheetAddStoryHere),
                    ),
                    const SizedBox(height: 20),
                    Text(l10n.placeSheetStoriesHeading, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    if (stories.isEmpty) Text(l10n.placeSheetNoStories),
                    ...stories.map((story) => _StoryTile(
                          event: story,
                          persons: allPersons,
                          recordingFileStore: _recordingFileStore,
                        )),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _StoryTile extends StatelessWidget {
  final Event event;
  final List<Person> persons;
  final RecordingFileStore recordingFileStore;

  const _StoryTile({
    required this.event,
    required this.persons,
    required this.recordingFileStore,
  });

  @override
  Widget build(BuildContext context) {
    final participantNames = event.participantIds
        .map((id) => persons.where((p) => p.id == id).firstOrNull?.name)
        .whereType<String>()
        .toList();
    final recordings = event.files.where((f) => f.isRecording).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => EventDetailScreen(eventId: event.id)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(event.title, style: Theme.of(context).textTheme.titleSmall),
                  Text(event.displayDate(Localizations.localeOf(context).toString()),
                      style: Theme.of(context).textTheme.bodySmall),
                  if (event.description != null) ...[
                    const SizedBox(height: 4),
                    Text(event.description!, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                ],
              ),
            ),
            if (participantNames.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                children: participantNames
                    .map((name) => ActionChip(
                          label: Text(name),
                          onPressed: () {
                            final person = persons.firstWhere((p) => p.name == name);
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => PersonDetailScreen(personId: person.id)),
                            );
                          },
                        ))
                    .toList(),
              ),
            ],
            for (final recording in recordings)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: RecordingPlayer(file: recording, store: recordingFileStore),
              ),
          ],
        ),
      ),
    );
  }
}
