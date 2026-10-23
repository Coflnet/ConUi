import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// Finds the closest mapped street address within 50m. Address lookup is a
/// convenience: an unavailable service or missing map data leaves naming to
/// the caller's localized coordinate fallback.
Future<String?> nearestStreetAddress(LatLng point,
    {http.Client? httpClient}) async {
  final client = httpClient ?? http.Client();
  try {
    final response = await client.get(Uri.https('photon.komoot.io', '/reverse', {
      'lat': '${point.latitude}',
      'lon': '${point.longitude}',
      'radius': '0.05', // Photon measures the search radius in kilometres.
      'limit': '10',
    })).timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) return null;
    final features = jsonDecode(response.body)['features'] as List;
    const distance = Distance();
    var nearestMeters = 50.0;
    var streetMeters = 50.0;
    String? nearest;
    String? nearestStreet;
    for (final feature in features) {
      final coordinates = feature['geometry']?['coordinates'];
      final properties = feature['properties'];
      final street = properties?['street'] ??
          (properties?['type'] == 'street' ? properties['name'] : null);
      final number = properties?['housenumber'];
      if (coordinates is! List ||
          coordinates.length < 2 ||
          coordinates[0] is! num ||
          coordinates[1] is! num ||
          street is! String ||
          street.trim().isEmpty) {
        continue;
      }
      final meters = distance.distance(point,
          LatLng(coordinates[1].toDouble(), coordinates[0].toDouble()));
      if (meters <= streetMeters) {
        streetMeters = meters;
        nearestStreet = street.trim();
      }
      if (number is String && number.trim().isNotEmpty && meters <= nearestMeters) {
        nearestMeters = meters;
        nearest = '${street.trim()} ${number.trim()}';
      }
    }
    return nearest ?? nearestStreet;
  } catch (_) {
    return null;
  } finally {
    if (httpClient == null) client.close();
  }
}
