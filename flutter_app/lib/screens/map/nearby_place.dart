import 'package:latlong2/latlong.dart';

import '../../models/models.dart';

/// A place is proposed as a match when an existing one lies within this
/// many meters of a picked position - close enough that it's almost
/// certainly the same spot, not a new one. Shared by the quick add sheet
/// and AddEventScreen's "pick on map" place action, so both apply the same
/// duplicate-avoidance rule.
const double kNearbyPlaceRadiusMeters = 50;

/// The closest of [places] to [point], if it's within
/// [kNearbyPlaceRadiusMeters] - otherwise null.
Place? findNearbyPlace(List<Place> places, LatLng point) {
  const distance = Distance();
  Place? nearest;
  var nearestMeters = double.infinity;
  for (final place in places) {
    final meters = distance.distance(point, LatLng(place.latitude, place.longitude));
    if (meters < nearestMeters) {
      nearestMeters = meters;
      nearest = place;
    }
  }
  return (nearest != null && nearestMeters <= kNearbyPlaceRadiusMeters) ? nearest : null;
}

/// A sensible default name for a place the user didn't name, derived from
/// its coordinates so it's still identifiable until they rename it.
String defaultPlaceName(LatLng point) =>
    'Unnamed place (${point.latitude.toStringAsFixed(3)}, ${point.longitude.toStringAsFixed(3)})';
