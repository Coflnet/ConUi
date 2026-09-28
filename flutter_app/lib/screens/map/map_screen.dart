import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/models.dart';
import '../../services/database_service.dart';
import '../../services/location_service.dart';
import '../../services/recording_file_store.dart';
import '../../services/recording_recovery_service.dart';
import '../../widgets/recovered_recordings_banner.dart';
import '../places/place_sheet.dart';
import '../quick_add/quick_add_sheet.dart';
import 'draggable_pin_marker.dart';
import 'map_tile_layer.dart';
import 'place_clustering.dart';

class _Strings {
  static const addStory = 'Add story';
  static const chooseAPlace = 'Choose a place';
}

/// The app's home tab and main entry point: a map of every place with a
/// story, always one tap away from adding a new one. See the project brief
/// for the full set of rules this implements.
///
/// Reuses (rather than duplicating) the map building blocks also used by
/// [PlaceSheet] and [LocationPickerScreen] - [StoryMapTileLayer] for tiles/
/// attribution and the last-remembered camera position, stored under the
/// same SharedPreferences keys the places list's own map view has always
/// used, so switching between the two tabs keeps the same view.
class MapScreen extends StatefulWidget {
  /// Overridable for tests, so a fake can be driven without real GPS.
  final LocationService? locationService;

  const MapScreen({super.key, this.locationService});

  @override
  State<MapScreen> createState() => MapScreenState();
}

class MapScreenState extends State<MapScreen> {
  static const _mapLatKey = 'places_map_lat';
  static const _mapLngKey = 'places_map_lng';
  static const _mapZoomKey = 'places_map_zoom';

  // Central Europe: the fallback view when there's no remembered position,
  // no existing place to fit to (see _maybeFitToPlaces, which takes over
  // as soon as any place loads) and no device location to use instead.
  static const _defaultCenter = LatLng(50, 10);
  static const _defaultZoom = 5.0;
  // Close enough to actually be useful once centered on the device, not
  // just a marginally-less-wide overview.
  static const _deviceLocationZoom = 12.0;

  final MapController _mapController = MapController();
  late final LocationService _locationService =
      widget.locationService ?? GeolocatorLocationService();
  late final RecordingFileStore _recordingFileStore = createRecordingFileStore();

  LatLng _center = _defaultCenter;
  double _zoom = _defaultZoom;
  bool _positionInitialized = false;
  bool _fittedToPlacesOnce = false;

  ValueNotifier<LatLng>? _pendingPin;
  double _currentZoom = _defaultZoom;

  /// Mirrors the map's current camera center, updated only from
  /// [onPositionChanged] (i.e. once the map has actually attached).
  /// MapController.camera throws until then, so anything read during
  /// build() - like the recovered-recordings banner's picker start
  /// position - must use this instead of reading the controller directly.
  /// Starts equal to [_center]'s own default and is corrected as soon as
  /// [_loadMapPosition] resolves.
  LatLng _lastKnownCenter = _defaultCenter;

  @override
  void initState() {
    super.initState();
    _loadMapPosition();
    WidgetsBinding.instance.addPostFrameCallback((_) => _recoverAbandonedRecordings());
  }

  Future<void> _loadMapPosition() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    final lat = prefs.getDouble(_mapLatKey);
    final lng = prefs.getDouble(_mapLngKey);
    if (lat != null && lng != null) {
      setState(() {
        _center = LatLng(lat, lng);
        _lastKnownCenter = _center;
        _zoom = prefs.getDouble(_mapZoomKey) ?? _zoom;
        _currentZoom = _zoom;
        _positionInitialized = true;
      });
      return;
    }

    // No remembered position yet (first launch, or a fresh install):
    // center on the device's own location if it's already allowed -
    // never asking for permission here, so this never pops an unprompted
    // dialog (see LocationService.hasPermission's doc comment) - falling
    // back to a central-Europe overview otherwise. _maybeFitToPlaces()
    // still takes over as soon as any place loads, so this only actually
    // matters for a brand new user with nothing to fit to yet.
    DeviceLocation? location;
    if (await _locationService.hasPermission()) {
      location = await _locationService.getCurrentLocation();
    }
    if (!mounted) return;
    setState(() {
      if (location != null) {
        _center = LatLng(location.latitude, location.longitude);
        _zoom = _deviceLocationZoom;
      }
      _lastKnownCenter = _center;
      _currentZoom = _zoom;
      _positionInitialized = true;
    });
  }

  Future<void> _saveMapPosition() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_mapLatKey, _lastKnownCenter.latitude);
    await prefs.setDouble(_mapLngKey, _lastKnownCenter.longitude);
    await prefs.setDouble(_mapZoomKey, _currentZoom);
  }

  Future<void> _recoverAbandonedRecordings() async {
    final db = context.read<DatabaseService>();
    final recovery = RecordingRecoveryService(_recordingFileStore, db);
    await recovery.recoverIncompleteRecordings();
    if (mounted) setState(() {}); // let the banner's own FutureBuilder re-query.
  }

  void _maybeFitToPlaces(List<Place> places) {
    if (_fittedToPlacesOnce || places.isEmpty || !_positionInitialized) return;
    _fittedToPlacesOnce = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (places.length == 1) {
        _mapController.move(LatLng(places.first.latitude, places.first.longitude), 14);
      } else {
        _mapController.fitCamera(CameraFit.coordinates(
          coordinates: places.map((p) => LatLng(p.latitude, p.longitude)).toList(),
          padding: const EdgeInsets.all(48),
        ));
      }
    });
  }

  Future<void> _startQuickAddAt(LatLng position) async {
    final notifier = ValueNotifier<LatLng>(position);
    setState(() => _pendingPin = notifier);
    final result = await QuickAddSheet.show(context, position: notifier);
    if (mounted) setState(() => _pendingPin = null);
    notifier.dispose();
    if (result != null && mounted) {
      setState(() {}); // refresh markers/story counts.
    }
  }

  Future<void> _addStoryButtonPressed() async {
    final location = await _locationService.getCurrentLocation();
    final position = location != null
        ? LatLng(location.latitude, location.longitude)
        : _lastKnownCenter;
    await _startQuickAddAt(position);
  }

  Future<void> _onMarkerTapped(MapMarkerGroup group) async {
    if (!group.isCluster) {
      await PlaceSheet.show(context, placeId: group.places.single.id);
      if (mounted) setState(() {});
      return;
    }
    final chosen = await showModalBottomSheet<Place>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text(_Strings.chooseAPlace)),
            const Divider(height: 1),
            ...group.places.map((place) => ListTile(
                  leading: const Icon(Icons.place),
                  title: Text(place.name),
                  onTap: () => Navigator.pop(context, place),
                )),
          ],
        ),
      ),
    );
    if (chosen != null && mounted) {
      await PlaceSheet.show(context, placeId: chosen.id);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_positionInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return Consumer<DatabaseService>(
      builder: (context, db, _) {
        return FutureBuilder<List<Object>>(
          future: Future.wait([db.getPlaces(), db.getEvents()]),
          builder: (context, snapshot) {
            final places = (snapshot.data?[0] as List<Place>?) ?? const [];
            final events = (snapshot.data?[1] as List<Event>?) ?? const [];
            _maybeFitToPlaces(places);

            final storyCounts = <String, int>{};
            for (final event in events) {
              final placeId = event.placeId;
              if (placeId == null) continue;
              storyCounts[placeId] = (storyCounts[placeId] ?? 0) + 1;
            }
            final groups = groupPlacesForZoom(places, storyCounts, _currentZoom);

            return Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _center,
                    initialZoom: _zoom,
                    onTap: (tapPosition, point) => _startQuickAddAt(point),
                    onPositionChanged: (position, hasGesture) {
                      _currentZoom = position.zoom ?? _currentZoom;
                      _lastKnownCenter = position.center ?? _lastKnownCenter;
                      if (hasGesture) {
                        _saveMapPosition();
                        setState(() {});
                      }
                    },
                  ),
                  children: [
                    const StoryMapTileLayer(),
                    MarkerLayer(
                      markers: groups
                          .map((group) => Marker(
                                point: group.position,
                                width: 56,
                                height: 56,
                                alignment: Alignment.topCenter,
                                child: GestureDetector(
                                  onTap: () => _onMarkerTapped(group),
                                  child: _PlaceMarker(group: group),
                                ),
                              ))
                          .toList(),
                    ),
                    if (_pendingPin != null)
                      DraggablePinMarker(mapController: _mapController, position: _pendingPin!),
                  ],
                ),
                Positioned(
                  top: 8,
                  left: 8,
                  right: 8,
                  child: RecoveredRecordingsBanner(
                    store: _recordingFileStore,
                    pickerStartPosition: _lastKnownCenter,
                  ),
                ),
                Positioned(
                  bottom: 24,
                  right: 16,
                  child: FloatingActionButton.extended(
                    onPressed: _addStoryButtonPressed,
                    icon: const Icon(Icons.add_location_alt),
                    label: const Text(_Strings.addStory),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _PlaceMarker extends StatelessWidget {
  final MapMarkerGroup group;

  const _PlaceMarker({required this.group});

  @override
  Widget build(BuildContext context) {
    final label = group.isCluster ? '${group.places.length}' : null;
    return Semantics(
      label: group.isCluster
          ? '${group.places.length} places, ${group.storyCount} stories'
          : '${group.places.single.name}, ${group.storyCount} stories',
      button: true,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(
            group.isCluster ? Icons.location_city : Icons.location_pin,
            color: group.isCluster ? Colors.deepPurple : Colors.red,
            size: 44,
          ),
          if (group.storyCount > 0)
            Positioned(
              right: 0,
              top: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${group.storyCount}',
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
              ),
            ),
          if (label != null)
            Positioned(
              left: 10,
              top: 10,
              child: Text(label,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
            ),
        ],
      ),
    );
  }
}
