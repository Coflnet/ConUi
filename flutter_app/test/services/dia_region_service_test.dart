import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:relationship_manager/services/dia_region_service.dart';
import 'package:relationship_manager/services/location_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Location implements LocationService {
  bool permission = true;
  DeviceLocation? point = const DeviceLocation(50, 10);
  int permissionChecks = 0, locationReads = 0;
  @override
  Future<bool> hasPermission() async {
    permissionChecks++;
    return permission;
  }

  @override
  Future<DeviceLocation?> getCurrentLocation() async {
    locationReads++;
    return point;
  }
}

class _RevokedPermission extends GeolocatorPlatform {
  int checks = 0, requests = 0;
  @override
  Future<bool> isLocationServiceEnabled() async => true;
  @override
  Future<LocationPermission> checkPermission() async =>
      checks++ == 0 ? LocationPermission.whileInUse : LocationPermission.denied;
  @override
  Future<LocationPermission> requestPermission() async {
    requests++;
    return LocationPermission.denied;
  }
}

void main() {
  late _Location location;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    location = _Location();
  });

  test('selected map pin overrides saved postcode and never reads GPS',
      () async {
    SharedPreferences.setMockInitialValues({
      'dia-region-zip': '80331',
      'dia-region-country': 'DE',
    });
    location.permission = false;
    final region = await suggestDiaRegion(
        selectedPosition: const LatLng(48.2, 16.37),
        locationService: location,
        httpClient: MockClient((request) async {
          expect(request.url.queryParameters,
              {'lat': '48.2', 'lon': '16.37', 'limit': '1'});
          return http.Response(
              '{"features":[{"properties":{"postcode":"1010","countrycode":"at"}}]}',
              200);
        }));
    expect(region!.zip, '1010');
    expect(region.country, 'AT');
    expect(location.permissionChecks, 0);
    expect(location.locationReads, 0);
  });

  test('unresolved map pin never falls back to an unrelated saved region',
      () async {
    SharedPreferences.setMockInitialValues({
      'dia-region-zip': '80331',
      'dia-region-country': 'DE',
    });
    expect(
        await suggestDiaRegion(
            selectedPosition: const LatLng(48.2, 16.37),
            locationService: location,
            httpClient: MockClient((_) async => http.Response('offline', 503))),
        isNull);
    expect(location.permissionChecks, 0);
    expect(location.locationReads, 0);
  });

  for (final saved in [
    {'dia-region-zip': ' 10115 ', 'dia-region-country': ' de '},
    {'dia-region-country': 'at'},
  ]) {
    test('honors nonempty saved region without requesting location: $saved',
        () async {
      SharedPreferences.setMockInitialValues(saved);
      final region = await suggestDiaRegion(
          locationService: location,
          httpClient:
              MockClient((_) async => throw StateError('No lookup allowed')));
      expect(region!.zip, (saved['dia-region-zip'] ?? '').trim());
      expect(region.country,
          (saved['dia-region-country'] ?? '').trim().toUpperCase());
      expect(location.permissionChecks, 0);
      expect(location.locationReads, 0);
    });
  }

  test('legacy blank saved fields allow permitted-location autofill', () async {
    SharedPreferences.setMockInitialValues({
      'dia-region-zip': '',
      'dia-region-country': ' ',
    });
    final region = await suggestDiaRegion(
        locationService: location,
        httpClient: MockClient((_) async => http.Response(
            '{"features":[{"properties":{"postcode":"10115","countrycode":"de"}}]}',
            200)));
    expect(region!.zip, '10115');
    expect(region.country, 'DE');
    expect(location.permissionChecks, 1);
    expect(location.locationReads, 1);
  });

  test('denied permission never requests location or makes a coordinate lookup',
      () async {
    location.permission = false;
    expect(
        await suggestDiaRegion(
            locationService: location,
            httpClient:
                MockClient((_) async => throw StateError('No lookup allowed'))),
        isNull);
    expect(location.permissionChecks, 1);
    expect(location.locationReads, 0);
  });

  test('permission revoked between checks never triggers a permission prompt',
      () async {
    final previous = GeolocatorPlatform.instance;
    final platform = _RevokedPermission();
    GeolocatorPlatform.instance = platform;
    addTearDown(() => GeolocatorPlatform.instance = previous);
    expect(
        await suggestDiaRegion(
            httpClient: MockClient(
                (_) async => throw StateError('No coordinate lookup allowed'))),
        isNull);
    expect(platform.checks, 2);
    expect(platform.requests, 0);
  });

  test(
      'uses current permitted location and closest Photon region, without saving an inferred choice',
      () async {
    final region = await suggestDiaRegion(
        locationService: location,
        httpClient: MockClient((request) async {
          expect(request.url.host, 'photon.komoot.io');
          expect(request.url.path, '/reverse');
          expect(request.url.queryParameters,
              {'lat': '50.0', 'lon': '10.0', 'limit': '1'});
          return http.Response(
              jsonEncode({
                'features': [
                  {
                    'properties': {'postcode': ' 10115 ', 'countrycode': ' de '}
                  },
                  {
                    'properties': {'postcode': '99999', 'countrycode': 'at'}
                  },
                ]
              }),
              200);
        }));
    expect(region!.zip, '10115');
    expect(region.country, 'DE');
    expect(location.locationReads, 1);
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });

  test('unavailable position leaves region blank without network access',
      () async {
    location.point = null;
    expect(
        await suggestDiaRegion(
            locationService: location,
            httpClient:
                MockClient((_) async => throw StateError('No lookup allowed'))),
        isNull);
  });

  test('can suggest country when the closest feature has no postcode',
      () async {
    final region = await suggestDiaRegion(
        locationService: location,
        httpClient: MockClient((_) async => http.Response(
            '{"features":[{"properties":{"countrycode":"ch"}}]}', 200)));
    expect(region!.zip, '');
    expect(region.country, 'CH');
  });

  for (final body in [
    '{"features":[]}',
    '{"features":[{"properties":{}}]}',
    'not json'
  ]) {
    test('missing or malformed reverse geocoding data is optional: $body',
        () async {
      expect(
          await suggestDiaRegion(
              locationService: location,
              httpClient: MockClient((_) async => http.Response(body, 200))),
          isNull);
    });
  }

  test('HTTP and network failure leave the optional region editable', () async {
    for (final client in [
      MockClient((_) async => http.Response('Busy', 429)),
      MockClient((_) async => throw http.ClientException('offline')),
    ]) {
      expect(
          await suggestDiaRegion(locationService: location, httpClient: client),
          isNull);
    }
  });
}
