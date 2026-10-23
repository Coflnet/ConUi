import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/screens/map/location_picker_screen.dart';

void main() {
  testWidgets('previews the mapped address at the initial position', (tester) async {
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LocationPickerScreen(initialPosition: LatLng(50, 10)),
      ));
      await tester.pump();
      expect(find.text('Mapped Street 12'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    }, () => MockClient((request) async => http.Response(jsonEncode({
      'features': [{
        'geometry': {'coordinates': [10, 50]},
        'properties': {'street': 'Mapped Street', 'housenumber': '12'},
      }],
    }), 200)));
  });

  testWidgets('first completed move ignores the pending initial address', (tester) async {
    final initial = Completer<http.Response>();
    var calls = 0;
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LocationPickerScreen(initialPosition: LatLng(50, 10)),
      ));
      final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
      map.mapController!.move(const LatLng(51, 11), 15);
      map.options.onMapEvent!(MapEventMoveEnd(
          source: MapEventSource.onDrag, camera: map.mapController!.camera));
      await tester.pump();
      await tester.pump();
      expect(find.text('New Street 2'), findsOneWidget);
      initial.complete(http.Response(jsonEncode({'features': [{
        'geometry': {'coordinates': [10, 50]},
        'properties': {'street': 'Old Street', 'housenumber': '1'},
      }]}), 200));
      await tester.pump();
      expect(find.text('Old Street 1'), findsNothing);
      expect(find.text('New Street 2'), findsOneWidget);
      expect(calls, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    }, () => MockClient((request) {
      if (request.url.host != 'photon.komoot.io') {
        return Future.value(http.Response('', 400));
      }
      calls++;
      if (request.url.queryParameters['lat'] == '50.0') return initial.future;
      return Future.value(http.Response(jsonEncode({'features': [{
        'geometry': {'coordinates': [11, 51]},
        'properties': {'street': 'New Street', 'housenumber': '2'},
      }]}), 200));
    }));
  });

  for (final language in ['en', 'de']) {
    testWidgets('$language cancel discards the adjusted position',
        (tester) async {
      var completed = false;
      LatLng? result;
      await tester.pumpWidget(MaterialApp(
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
            builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      result = await Navigator.push<LatLng>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const LocationPickerScreen(
                                initialPosition: LatLng(50, 10)),
                          ));
                      completed = true;
                    },
                    child: const Text('Open'),
                  ),
                )),
      ));
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
      map.mapController!.move(const LatLng(51, 11), 15);
      await tester.pump();
      final cancel = find.widgetWithText(
          TextButton, language == 'de' ? 'Abbrechen' : 'Cancel');
      expect(tester.getTopLeft(cancel).dx, lessThan(100));
      await tester.tap(cancel);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(completed, isTrue);
      expect(result, isNull);
      expect(find.byType(LocationPickerScreen), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('confirm returns the adjusted position', (tester) async {
    LatLng? result;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
          builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await Navigator.push<LatLng>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const LocationPickerScreen(
                              initialPosition: LatLng(50, 10)),
                        ));
                  },
                  child: const Text('Open'),
                ),
              )),
    ));
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!
        .move(const LatLng(51, 11), 15);
    await tester.pump();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(result!.latitude, closeTo(51, 0.00001));
    expect(result!.longitude, closeTo(11, 0.00001));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
