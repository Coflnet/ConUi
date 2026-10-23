import 'package:latlong2/latlong.dart';

import '../../models/models.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../l10n/gen/app_localizations_en.dart';
import '../../l10n/gen/app_localizations_de.dart';
import '../../services/address_service.dart';

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
String defaultPlaceName(LatLng point, AppLocalizations l10n) =>
    l10n.placeDefaultName(point.latitude.toStringAsFixed(3),
        point.longitude.toStringAsFixed(3));

Future<String> resolveDefaultPlaceName(
        LatLng point, AppLocalizations l10n) async =>
    await nearestStreetAddress(point) ?? defaultPlaceName(point, l10n);

/// Only generated coordinate names may be replaced automatically, including
/// places created before the user switched language.
bool hasDefaultPlaceName(Place place) {
  final point = LatLng(place.latitude, place.longitude);
  return [AppLocalizationsEn(), AppLocalizationsDe()]
      .any((l10n) => place.name == defaultPlaceName(point, l10n));
}
