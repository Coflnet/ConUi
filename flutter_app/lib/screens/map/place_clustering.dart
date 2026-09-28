import 'package:latlong2/latlong.dart';

import '../../models/models.dart';

/// One thing to show as a marker on the story map: either a single place,
/// or several nearby places grouped together so the map stays usable when
/// zoomed out and many places would otherwise overlap.
class MapMarkerGroup {
  final LatLng position;
  final List<Place> places;

  /// Total number of stories across every place in this group - what the
  /// marker's badge shows.
  final int storyCount;

  MapMarkerGroup({
    required this.position,
    required this.places,
    required this.storyCount,
  });

  bool get isCluster => places.length > 1;
}

/// Groups [places] into [MapMarkerGroup]s to display at the given [zoom].
///
/// This uses simple grid-based thinning rather than a clustering package or
/// screen-space (pixel distance) clustering: places are bucketed onto a
/// lat/lng grid whose cell size shrinks as [zoom] increases, and every
/// place sharing a cell becomes one combined marker. From zoom 14 onward
/// (roughly city-block scale) every place gets its own marker, since by
/// then they're naturally far enough apart on screen. This was chosen over
/// a proper clustering algorithm because it needs no extra dependency, no
/// pixel-geometry math tied to the current viewport, and is trivial to unit
/// test (it's a pure function of lat/lng + zoom) - simple enough for the
/// number of places one family's stories are ever likely to produce, while
/// still keeping a zoomed-out world view from drowning in overlapping pins.
List<MapMarkerGroup> groupPlacesForZoom(
  List<Place> places,
  Map<String, int> storyCountsByPlaceId,
  double zoom,
) {
  if (places.isEmpty) return const [];

  if (zoom >= 14) {
    return places
        .map((place) => MapMarkerGroup(
              position: LatLng(place.latitude, place.longitude),
              places: [place],
              storyCount: storyCountsByPlaceId[place.id] ?? 0,
            ))
        .toList();
  }

  // Degrees per grid cell: ~20° at zoom 0, halving every 2 zoom levels down
  // to a small fraction of a degree as zoom approaches 14.
  final cellSize = 20 / (1 << (zoom ~/ 2).clamp(0, 12));
  final buckets = <String, List<Place>>{};
  for (final place in places) {
    final cellLat = (place.latitude / cellSize).floor();
    final cellLng = (place.longitude / cellSize).floor();
    buckets.putIfAbsent('$cellLat:$cellLng', () => []).add(place);
  }

  return buckets.values.map((group) {
    final avgLat = group.map((p) => p.latitude).reduce((a, b) => a + b) / group.length;
    final avgLng = group.map((p) => p.longitude).reduce((a, b) => a + b) / group.length;
    final totalStories =
        group.fold<int>(0, (sum, p) => sum + (storyCountsByPlaceId[p.id] ?? 0));
    return MapMarkerGroup(
      position: LatLng(avgLat, avgLng),
      places: group,
      storyCount: totalStories,
    );
  }).toList();
}
