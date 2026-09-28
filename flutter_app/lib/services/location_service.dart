import 'package:geolocator/geolocator.dart';

/// A plain (lat, lng) pair, decoupled from geolocator's `Position` so
/// callers - and tests, via a fake - don't need the plugin at all.
class DeviceLocation {
  final double latitude;
  final double longitude;

  const DeviceLocation(this.latitude, this.longitude);
}

/// Thin wrapper around the geolocator plugin, so the rest of the app never
/// depends on it directly (and tests can fake it - no real GPS in CI).
///
/// Every failure mode - location services disabled, permission denied
/// (once or permanently), a timeout, or any other error - is reported the
/// same way: a null result. Callers (the map's "Add story" button) are
/// expected to fall back to the map's current center rather than blocking
/// or showing an error; the whole point is that adding a story never
/// stalls on a permission dialog the user dismisses.
abstract class LocationService {
  Future<DeviceLocation?> getCurrentLocation();

  /// True if location permission has already been granted, without ever
  /// asking for it. Used for something passive (the map's very first
  /// view, before the user has done anything) that should use the
  /// device's location when it's already allowed, but must never itself
  /// pop an unprompted permission dialog - see [getCurrentLocation]'s doc
  /// comment for why only an explicit user action gets to do that.
  Future<bool> hasPermission();
}

class GeolocatorLocationService implements LocationService {
  @override
  Future<bool> hasPermission() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;
      final permission = await Geolocator.checkPermission();
      return permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<DeviceLocation?> getCurrentLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
      ).timeout(const Duration(seconds: 10));
      return DeviceLocation(position.latitude, position.longitude);
    } catch (_) {
      // Anything else (timeout, plugin not available on this platform,
      // browser denied the JS geolocation prompt, ...) - fall back
      // gracefully rather than surfacing an error for a convenience
      // feature.
      return null;
    }
  }
}
