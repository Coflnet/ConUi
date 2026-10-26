import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/screens/map/location_picker_screen.dart';

void main() {
  for (final language in ['en', 'de']) {
    testWidgets('$language failed tiles retry without losing the selected pin',
        (tester) async {
      // Each locale starts cold; successful tiles from the previous case must
      // not bypass this case's simulated outage.
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      final failedUrls = <Uri>{};
      final recoveredUrls = <Uri>{};
      var recovered = false;
      LatLng? selected;
      await http.runWithClient(() async {
        await tester.pumpWidget(MaterialApp(
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  selected = await Navigator.push<LatLng>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const LocationPickerScreen(
                        initialPosition: LatLng(50, 10),
                      ),
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
        final mapState = tester.state(find.byType(FlutterMap));
        map.mapController!.move(const LatLng(51, 11), 14);
        await tester.pumpAndSettle();
        final message = language == 'de'
            ? 'Die Karte konnte nicht geladen werden. Prüfen Sie Ihre Verbindung und versuchen Sie es erneut.'
            : 'Could not load the map. Check your connection and retry.';
        expect(failedUrls, isNotEmpty);
        expect(find.text(message), findsOneWidget);
        expect(find.text('© OpenStreetMap contributors'), findsOneWidget);

        recovered = true;
        await tester.tap(find.widgetWithText(
          TextButton,
          language == 'de' ? 'Erneut versuchen' : 'Retry',
        ));
        await tester.pumpAndSettle();
        expect(recoveredUrls.intersection(failedUrls), isNotEmpty,
            reason: 'Retry must fetch tiles that previously failed, not reuse errors.');
        expect(find.text(message), findsNothing);
        expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
        expect(tester.state(find.byType(FlutterMap)), same(mapState));
        expect(map.mapController!.camera.center, const LatLng(51, 11));
        expect(map.mapController!.camera.zoom, 14);
        await tester.tap(find.byType(FloatingActionButton));
        await tester.pumpAndSettle();
        expect(selected, const LatLng(51, 11));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => MockClient((request) async {
        if (request.url.host != 'tile.openstreetmap.org') {
          return http.Response('{"features":[]}', 200);
        }
        if (!recovered) {
          failedUrls.add(request.url);
          return http.Response('Map unavailable', 400);
        }
        recoveredUrls.add(request.url);
        return http.Response.bytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          ),
          200,
        );
      }));
    });
  }
}
