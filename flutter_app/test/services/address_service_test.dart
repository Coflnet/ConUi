import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:relationship_manager/services/address_service.dart';

void main() {
  const point = LatLng(50, 10);

  Map<String, dynamic> address(double lat, String street, String number) =>
      {
        'geometry': {
          'type': 'Point',
          'coordinates': [10, lat]
        },
        'properties': {'street': street, 'housenumber': number},
      };

  test(
      'queries a 50m radius and picks the closest address, including buildings',
      () async {
    final client = MockClient((request) async {
      expect(request.url.host, 'photon.komoot.io');
      expect(request.method, 'GET');
      expect(request.url.path, '/reverse');
      expect(request.url.queryParameters['radius'], '0.05');
      expect(request.url.queryParameters['lat'], '50.0');
      expect(request.url.queryParameters['lon'], '10.0');
      return http.Response(
          jsonEncode({
            'features': [
              address(50.0003, 'Farther Street', '9'),
              address(50.0001, ' Nearby Street ', ' 12 '),
              address(50.0002, 'Other Street', '1'),
            ]
          }),
          200);
    });
    expect(await nearestStreetAddress(point, httpClient: client),
        'Nearby Street 12');
  });

  test('uses the nearest street when no house number is mapped', () async {
    final client = MockClient((_) async => http.Response(
        jsonEncode({
          'features': [
            {
              'geometry': {
                'coordinates': [10, 50.0001]
              },
              'properties': {'type': 'street', 'name': 'Street Only'}
            },
          ]
        }),
        200));
    expect(
        await nearestStreetAddress(point, httpClient: client), 'Street Only');
  });

  test('prefers a numbered address over a closer unnumbered street', () async {
    final client = MockClient((_) async => http.Response(
        jsonEncode({
          'features': [
            address(50, 'Street Only', ''),
            address(50.0001, 'House', '3')
          ]
        }),
        200));
    expect(await nearestStreetAddress(point, httpClient: client), 'House 3');
  });

  test('does not name places after addresses beyond 50m', () async {
    final client = MockClient((_) async => http.Response(
        jsonEncode({
          'features': [
            address(50.00046, 'Too Far Street', '1'),
          ]
        }),
        200));
    expect(await nearestStreetAddress(point, httpClient: client), isNull);
  });

  test('skips incomplete addresses and still finds a valid candidate',
      () async {
    final incomplete = address(50, '', '1');
    final client = MockClient((_) async => http.Response(
        jsonEncode({
          'features': [
            incomplete,
            {
              'properties': {
                'street': 'Missing Coordinates',
                'housenumber': '2'
              }
            },
            address(50.0001, 'Valid Street', '3'),
          ]
        }),
        200));
    expect(await nearestStreetAddress(point, httpClient: client),
        'Valid Street 3');
  });

  for (final body in ['{"features":[]}', 'not json', '{"remark":"timeout"}']) {
    test('returns no address for unavailable data: $body', () async {
      final client = MockClient((_) async => http.Response(body, 200));
      expect(await nearestStreetAddress(point, httpClient: client), isNull);
    });
  }

  test('returns no address when HTTP fails', () async {
    final client = MockClient((_) async => http.Response('Busy', 429));
    expect(await nearestStreetAddress(point, httpClient: client), isNull);
  });

  test('returns no address when offline', () async {
    final client =
        MockClient((_) async => throw http.ClientException('offline'));
    expect(await nearestStreetAddress(point, httpClient: client), isNull);
  });
}
