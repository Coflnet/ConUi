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
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:relationship_manager/screens/map/map_screen.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/location_service.dart';

class _FakeLocationService implements LocationService {
  @override
  Future<DeviceLocation?> getCurrentLocation() async => null;
}

DatabaseService _freshDb(Directory tempDir) {
  sqfliteFfiInit();
  return DatabaseService(factory: databaseFactoryFfi, path: '${tempDir.path}/test.db');
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('map_screen_test');
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('renders the map, the Add story button and no recovered-recordings banner crash',
      (tester) async {
    late DatabaseService db;
    await tester.runAsync(() async {
      db = _freshDb(tempDir);
      await db.initialize();
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<DatabaseService>.value(
        value: db,
        child: MaterialApp(
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
}
