import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/screens/map/map_screen.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/location_service.dart';

import '../../support/localized_app.dart';

class _Database extends DatabaseService {
  final int storyCount;
  _Database(this.storyCount);

  @override
  Future<List<Place>> getPlaces({bool includeDeleted = false}) async => [
        for (var i = 0; i < 5; i++)
          Place(
              id: '$i',
              name: 'Place $i',
              latitude: 50.01 + i * .001,
              longitude: 10),
        Place(id: 'far', name: 'Far away', latitude: -20, longitude: -30),
      ];

  @override
  Future<List<Event>> getEvents(
          {String? monthKey, bool includeDeleted = false}) async =>
      [
        for (var i = 0; i < storyCount; i++)
          Event(
              title: 'Story $i', dateTime: DateTime(2026), placeId: '${i % 5}'),
        Event(title: 'Far story', dateTime: DateTime(2026), placeId: 'far'),
      ];

  @override
  Future<List<LocalRecordingState>> getLocalRecordingsByState(
          RecordingLifecycleState state) async =>
      [];
}

class _Location implements LocationService {
  @override
  Future<bool> hasPermission() async => false;
  @override
  Future<DeviceLocation?> getCurrentLocation() async => null;
}

void main() {
  for (final (locale, count, scale) in [('en', 6, 1.0), ('de', 123, 2.0)]) {
    testWidgets(
        '$locale cluster shows only story count at text scale $scale and opens place chooser',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final semantics = tester.ensureSemantics();
      final db = _Database(count);
      addTearDown(db.dispose);

      try {
        await http.runWithClient(() async {
          await tester.pumpWidget(ChangeNotifierProvider<DatabaseService>.value(
            value: db,
            child: wrapLocalized(MapScreen(locationService: _Location()),
                locale: Locale(locale)),
          ));
          // Allow preferences, data loading and the initial camera fit to finish.
          for (var i = 0; i < 4; i++) {
            await tester.pump(const Duration(milliseconds: 350));
          }

          final l10n =
              AppLocalizations.of(tester.element(find.byType(MapScreen)));
          final cluster = find
              .bySemanticsLabel(l10n.mapClusterStoryCountSemantics(5, count));
          final countText =
              find.descendant(of: cluster, matching: find.text('$count'));
          expect(cluster, findsOneWidget);
          expect(countText, findsOneWidget);
          expect(find.descendant(of: cluster, matching: find.byType(Text)),
              findsOneWidget);
          expect(
              find.descendant(
                  of: cluster, matching: find.byIcon(Icons.auto_stories)),
              findsOneWidget);
          expect(find.byIcon(Icons.location_city), findsNothing);
          expect(find.byIcon(Icons.location_pin), findsOneWidget);
          expect(
              find.bySemanticsLabel(
                  l10n.mapPlaceStoryCountSemantics('Far away', 1)),
              findsOneWidget);
          final markerRect = tester.getRect(cluster);
          expect(
              markerRect.contains(tester.getRect(countText).topLeft), isTrue);
          expect(markerRect.contains(tester.getRect(countText).bottomRight),
              isTrue);
          final iconRect = tester.getRect(find.descendant(
              of: cluster, matching: find.byIcon(Icons.auto_stories)));
          expect(iconRect.overlaps(tester.getRect(countText)), isFalse);
          expect(tester.takeException(), isNull);

          await tester.tap(cluster);
          await tester.pumpAndSettle();
          expect(find.text(l10n.mapChooseAPlace), findsOneWidget);
          for (var i = 0; i < 5; i++) {
            expect(find.text('Place $i'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        },
            () => MockClient((_) async => http.Response.bytes(
                base64Decode(
                    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='),
                200)));
      } finally {
        semantics.dispose();
      }
    });
  }
}
