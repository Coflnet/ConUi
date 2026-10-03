// Regression test: MapScreen's first build used to read
// _mapController.camera before the FlutterMap had attached (to pass the
// recovered-recordings banner its initial picker position), which throws
// LateInitializationError inside flutter_map's MapController - discovered
// only when actually running the app in a browser, since a plain
// FlutterMap-in-a-widget-test doesn't reliably reproduce flutter_map's
// internal camera attachment timing. The fix tracks the last known center
// itself (updated from onPositionChanged) instead of reading the
// controller during build. This test pumps the real screen (not a stub)
// so a regression there throws here too.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/screens/map/map_screen.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/location_service.dart';

import '../../support/test_database.dart';

class _FakeLocationService implements LocationService {
  _FakeLocationService({this.permitted = false, this.location});

  final bool permitted;
  final DeviceLocation? location;

  @override
  Future<bool> hasPermission() async => permitted;

  @override
  Future<DeviceLocation?> getCurrentLocation() async => location;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('renders the map, the Add story button and no recovered-recordings banner crash',
      (tester) async {
    late DatabaseService db;
    await tester.runAsync(() async {
      db = createTestDatabaseService();
      await db.initialize();
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<DatabaseService>.value(
        value: db,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MapScreen(locationService: _FakeLocationService()),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }

    expect(tester.takeException(), isNull,
        reason: 'MapScreen must not throw or overflow on its very first build');
    expect(find.widgetWithText(FloatingActionButton, 'Add story'), findsOneWidget);
  });

  group('default position (no remembered position, no places yet)', () {
    // Regression test: the map used to default to Paris (leftover from
    // old code) regardless of where the user actually is. It must fall
    // back to a central-Europe overview, or - when already allowed,
    // without ever asking for permission itself - the device's own
    // location.
    Future<void> pumpMap(WidgetTester tester, DatabaseService db, LocationService location) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<DatabaseService>.value(
          value: db,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: MapScreen(locationService: location),
          ),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
    }

    testWidgets('multiple places at the same coordinates keep a finite useful camera',
        (tester) async {
      late DatabaseService db;
      await tester.runAsync(() async {
        db = createTestDatabaseService();
        await db.initialize();
        for (final id in ['first', 'second']) {
          await db.savePlace(Place(id: id, name: id, latitude: 50, longitude: 10));
        }
      });
      await pumpMap(tester, db, _FakeLocationService());
      final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
      final camera = map.mapController!.camera;
      expect(camera.zoom.isFinite, isTrue);
      expect(camera.zoom, 14);
      expect(camera.center.latitude, closeTo(50, 0.000001));
      expect(camera.center.longitude, closeTo(10, 0.000001));
      expect(tester.takeException(), isNull);
    });

    testWidgets('without location permission, centers on central Europe at a wide zoom',
        (tester) async {
      late DatabaseService db;
      await tester.runAsync(() async {
        db = createTestDatabaseService();
        await db.initialize();
      });

      await pumpMap(tester, db, _FakeLocationService(permitted: false));

      final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
      expect(map.options.initialCenter, const LatLng(50, 10));
      expect(map.options.initialZoom, 5.0);
    });

    testWidgets('with location permission already granted, centers on the device instead',
        (tester) async {
      late DatabaseService db;
      await tester.runAsync(() async {
        db = createTestDatabaseService();
        await db.initialize();
      });

      await pumpMap(
        tester,
        db,
        _FakeLocationService(permitted: true, location: const DeviceLocation(52.52, 13.405)),
      );

      final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
      expect(map.options.initialCenter, const LatLng(52.52, 13.405));
      expect(map.options.initialZoom, 12.0);
    });
  });
}
