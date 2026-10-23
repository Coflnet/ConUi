import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:relationship_manager/services/address_service.dart';

void main() {
  const point = LatLng(50, 10);

  Map<String, dynamic> address(double lat, String street, String number,
          {bool center = false}) =>
      {
        if (center)
          'center': {'lat': lat, 'lon': 10}
        else ...{'lat': lat, 'lon': 10},
        'tags': {'addr:street': street, 'addr:housenumber': number},
      };

  test(
      'queries a 50m radius and picks the closest address, including buildings',
      () async {
    final client = MockClient((request) async {
      expect(request.url.host, 'overpass-api.de');
      expect(request.method, 'POST');
      final query = Uri.splitQueryString(request.body)['data']!;
      expect(query, contains('around:50,50.0,10.0'));
      expect(query, contains('["addr:street"]["addr:housenumber"]'));
      return http.Response(
          jsonEncode({
            'elements': [
              address(50.0003, 'Farther Street', '9'),
              address(50.0001, ' Nearby Street ', ' 12 ', center: true),
              address(50.0002, 'Other Street', '1'),
            ]
          }),
          200);
    });
    expect(await nearestStreetAddress(point, httpClient: client),
        'Nearby Street 12');
  });

  test('does not name places after addresses beyond 50m', () async {
    final client = MockClient((_) async => http.Response(
        jsonEncode({
          'elements': [
            address(50.00046, 'Too Far Street', '1', center: true),
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
          'elements': [
            incomplete,
            {
              'tags': {
                'addr:street': 'Missing Coordinates',
                'addr:housenumber': '2'
              }
            },
            address(50.0001, 'Valid Street', '3'),
          ]
        }),
        200));
    expect(await nearestStreetAddress(point, httpClient: client),
        'Valid Street 3');
  });

  for (final body in ['{"elements":[]}', 'not json', '{"remark":"timeout"}']) {
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
