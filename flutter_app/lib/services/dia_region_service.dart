import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'location_service.dart';

class DiaRegion {
  final String zip, country;
  const DiaRegion({required this.zip, required this.country});
}

/// Nonempty saved choices win over the current region. Callers keep fields
/// editable and must not replace edits made while this suggestion is loading.
Future<DiaRegion?> suggestDiaRegion({
  LocationService? locationService,
  http.Client? httpClient,
}) async {
  http.Client? client;
  try {
    final prefs = await SharedPreferences.getInstance();
    final zip = prefs.getString('dia-region-zip')?.trim() ?? '';
    final country = prefs.getString('dia-region-country')?.trim() ?? '';
    if (zip.isNotEmpty || country.isNotEmpty) {
      return DiaRegion(zip: zip, country: country.toUpperCase());
    }
    final location =
        locationService ?? GeolocatorLocationService(requestPermission: false);
    if (!await location.hasPermission()) return null;
    final point = await location.getCurrentLocation();
    if (point == null) return null;
    client = httpClient ?? http.Client();
    final response = await client
        .get(Uri.https('photon.komoot.io', '/reverse', {
          'lat': '${point.latitude}',
          'lon': '${point.longitude}',
          'limit': '1',
        }))
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) return null;
    final features = jsonDecode(response.body)['features'] as List;
    if (features.isEmpty) return null;
    final properties = features.first['properties'] as Map;
    final postcode = (properties['postcode'] as String?)?.trim() ?? '';
    final countryCode = (properties['countrycode'] as String?)?.trim() ?? '';
    if (postcode.isEmpty && countryCode.isEmpty) return null;
    return DiaRegion(zip: postcode, country: countryCode.toUpperCase());
  } catch (_) {
    // Region is optional; missing permission or map data leaves it editable.
    return null;
  } finally {
    if (httpClient == null) client?.close();
  }
}
