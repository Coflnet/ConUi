import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/screens/map/map_screen.dart';
import 'package:relationship_manager/screens/map/location_picker_screen.dart';
import 'package:relationship_manager/screens/places/place_sheet.dart';
import 'package:relationship_manager/screens/places/places_screen.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/location_service.dart';

class _Database extends DatabaseService {
  final List<Place> places = [];
  bool failRead = false;
  bool failSave = false;

  @override
  Future<List<Place>> getPlaces({bool includeDeleted = false}) async {
    if (failRead) throw StateError('test read failure');
    return places;
  }

  @override
  Future<Place?> getPlace(String id) async {
    if (failRead) throw StateError('test read failure');
    return places.where((p) => p.id == id).firstOrNull;
  }

  @override
  Future<void> savePlace(Place place, {bool recordPendingChange = true}) async {
    if (failSave) throw StateError('test save failure');
    places.removeWhere((p) => p.id == place.id);
    places.add(place);
    notifyListeners();
  }

  @override
  Future<List<Event>> getEvents(
          {String? monthKey, bool includeDeleted = false}) async =>
      [];
  @override
  Future<List<Person>> getPersons({bool includeDeleted = false}) async => [];
  @override
  Future<List<LocalRecordingState>> getLocalRecordingsByState(
          RecordingLifecycleState state) async =>
      [];
}

class _Location extends LocationService {
  final Completer<DeviceLocation?>? result;
  int calls = 0;
  _Location({this.result});
  @override
  Future<bool> hasPermission() async => false;
  @override
  Future<DeviceLocation?> getCurrentLocation() async {
    calls++;
    return result?.future;
  }
}

Widget _app(_Database db, Widget child) =>
    ChangeNotifierProvider<DatabaseService>.value(
      value: db,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    );

Future<void> _pump(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

http.Response _tile() => http.Response.bytes(
    base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='),
    200);

void _testWidgets(String name, WidgetTesterCallback body) {
  testWidgets(
      name,
      (tester) => http.runWithClient(
          () => body(tester),
          () => MockClient((request) async =>
              request.url.host == 'photon.komoot.io'
                  ? http.Response('{"features":[]}', 200)
                  : _tile())));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  _testWidgets(
      'Add Place requires an explicit position and never defaults to zero',
      (tester) async {
    final db = _Database();
    await tester.pumpWidget(_app(db, const PlacesScreen()));
    await _pump(tester);
    await tester.tap(find.widgetWithText(FloatingActionButton, 'Add Place'));
    await _pump(tester);
    await tester.enterText(find.byType(TextField).first, 'My place');
    await tester.tap(find.widgetWithText(TextButton, 'Add'));
    await _pump(tester);
    expect(find.text('Choose a location before adding this place.'),
        findsOneWidget);
    expect(db.places, isEmpty);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await _pump(tester);
  });

  for (final manual in [false, true]) {
    _testWidgets(
        'picked position uses address default and preserves manual=$manual name on retry',
        (tester) async {
      await http.runWithClient(() async {
        final db = _Database()..failSave = true;
        await tester.pumpWidget(_app(db, const PlacesScreen()));
        await _pump(tester);
        await tester
            .tap(find.widgetWithText(FloatingActionButton, 'Add Place'));
        await _pump(tester);
        if (manual) {
          await tester.enterText(find.byType(TextField).first, 'My place');
        }
        await tester
            .tap(find.widgetWithText(OutlinedButton, 'Choose a location'));
        await _pump(tester);
        final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
        map.mapController!.move(const LatLng(-33.86, 151.21), 15);
        await tester.pump();
        await tester.tap(
            find.widgetWithText(FloatingActionButton, 'Use this location'));
        await _pump(tester);
        await tester.tap(find.widgetWithText(TextButton, 'Add'));
        await _pump(tester);
        expect(
            find.textContaining('Could not save this place.'), findsOneWidget);
        expect(db.places, isEmpty);
        if (manual) expect(find.text('My place'), findsOneWidget);
        db.failSave = false;
        await tester.tap(find.widgetWithText(TextButton, 'Add'));
        await _pump(tester);
        expect(db.places, hasLength(1));
        expect(db.places.single.latitude, closeTo(-33.86, 0.000001));
        expect(db.places.single.longitude, closeTo(151.21, 0.000001));
        expect(
            db.places.single.name, manual ? 'My place' : 'Harbour Street 12');
        expect(find.byType(AlertDialog), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      },
          () => MockClient(
              (request) async => request.url.host == 'photon.komoot.io'
                  ? http.Response(
                      jsonEncode({
                        'features': [
                          {
                            'geometry': {
                              'coordinates': [151.21, -33.86]
                            },
                            'properties': {
                              'street': 'Harbour Street',
                              'housenumber': '12'
                            },
                          }
                        ]
                      }),
                      200)
                  : _tile()));
    });
  }

  for (final screen in ['places', 'place', 'map']) {
    _testWidgets('$screen loading error has a retry that restores saved data',
        (tester) async {
      final db = _Database()..failRead = true;
      db.places.add(
          Place(id: 'p', name: 'Saved place', latitude: 50, longitude: 10));
      final widget = switch (screen) {
        'places' => const PlacesScreen(),
        'place' => const PlaceSheet(placeId: 'p'),
        _ => MapScreen(locationService: _Location()),
      };
      await tester.pumpWidget(_app(db, widget));
      await _pump(tester);
      expect(find.text('Could not load your saved data. Try again.'),
          findsOneWidget);
      expect(find.text('No places yet'), findsNothing);
      db.failRead = false;
      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await _pump(tester);
      expect(find.text('Could not load your saved data. Try again.'),
          findsNothing);
      if (screen == 'map') {
        expect(find.byType(FlutterMap), findsOneWidget);
      } else {
        expect(find.text('Saved place'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  _testWidgets(
      'GPS request shows progress once and unavailable position requires a choice',
      (tester) async {
    final result = Completer<DeviceLocation?>();
    final location = _Location(result: result);
    await tester
        .pumpWidget(_app(_Database(), MapScreen(locationService: location)));
    await _pump(tester);
    await tester.tap(find.widgetWithText(FloatingActionButton, 'Add story'));
    await tester.pump();
    expect(find.text('Finding your location…'), findsOneWidget);
    expect(
        tester
            .widget<FloatingActionButton>(find.byType(FloatingActionButton))
            .onPressed,
        isNull);
    expect(location.calls, 1);
    result.complete(null);
    await _pump(tester);
    expect(find.text('Your current location is unavailable'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Choose a location'));
    await _pump(tester);
    expect(find.byType(LocationPickerScreen), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await _pump(tester);
    expect(
        find.widgetWithText(FloatingActionButton, 'Add story'), findsOneWidget);
    expect(find.byType(LocationPickerScreen), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  _testWidgets('large place clusters can scroll to every choice on a phone',
      (tester) async {
    tester.view.physicalSize = const Size(390, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = _Database();
    for (var i = 0; i < 30; i++) {
      db.places.add(Place(
          name: 'Cluster place $i', latitude: 50 + i * .000001, longitude: 10));
    }
    await tester.pumpWidget(_app(db, MapScreen(locationService: _Location())));
    await _pump(tester);
    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.mapController!.move(const LatLng(50, 10), 5);
    db.notifyListeners();
    await _pump(tester);
    await tester.tap(find.bySemanticsLabel(RegExp('30 places')));
    await _pump(tester);
    await tester.scrollUntilVisible(find.text('Cluster place 29'), 200,
        scrollable: find.byType(Scrollable).last);
    expect(find.text('Cluster place 29').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
