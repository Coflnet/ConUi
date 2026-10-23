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
    final response = await client.post(
      Uri.parse('https://overpass-api.de/api/interpreter'),
      body: {
        'data': '[out:json][timeout:3];'
            'nwr(around:50,${point.latitude},${point.longitude})'
            '["addr:street"]["addr:housenumber"];out center;',
      },
    ).timeout(const Duration(seconds: 4));
    if (response.statusCode != 200) return null;
    final elements = jsonDecode(response.body)['elements'] as List;
    const distance = Distance();
    var nearestMeters = 50.0;
    String? nearest;
    for (final element in elements) {
      final coordinates = element['center'] ?? element;
      final lat = coordinates['lat'];
      final lon = coordinates['lon'];
      final tags = element['tags'];
      final street = tags?['addr:street'];
      final number = tags?['addr:housenumber'];
      if (lat is! num ||
          lon is! num ||
          street is! String ||
          street.trim().isEmpty ||
          number is! String ||
          number.trim().isEmpty) {
        continue;
      }
      final meters =
          distance.distance(point, LatLng(lat.toDouble(), lon.toDouble()));
      if (meters <= nearestMeters) {
        nearestMeters = meters;
        nearest = '${street.trim()} ${number.trim()}';
      }
    }
    return nearest;
  } catch (_) {
    return null;
  } finally {
    if (httpClient == null) client.close();
  }
}
