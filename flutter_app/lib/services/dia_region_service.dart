import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'location_service.dart';

class DiaRegion {
  final String zip, country;
  const DiaRegion({required this.zip, required this.country});
}

/// The selected story position wins over saved choices and device location.
/// Suggestions must not replace edits made while they are loading.
Future<DiaRegion?> suggestDiaRegion({
  LatLng? selectedPosition,
  LocationService? locationService,
  http.Client? httpClient,
}) async {
  http.Client? client;
  try {
    if (selectedPosition == null) {
      final prefs = await SharedPreferences.getInstance();
      final zip = prefs.getString('dia-region-zip')?.trim() ?? '';
      final country = prefs.getString('dia-region-country')?.trim() ?? '';
      if (zip.isNotEmpty || country.isNotEmpty) {
        return DiaRegion(zip: zip, country: country.toUpperCase());
      }
    }
    var point = selectedPosition;
    if (point == null) {
      final location = locationService ??
          GeolocatorLocationService(requestPermission: false);
      if (!await location.hasPermission()) return null;
      final device = await location.getCurrentLocation();
      if (device != null) point = LatLng(device.latitude, device.longitude);
    }
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
