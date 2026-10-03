// Widget tests for PlaceSheet: name (editable), stories at that place in
// date order with their persons, and "Add story here".
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/screens/places/place_sheet.dart';
import 'package:relationship_manager/screens/quick_add/quick_add_sheet.dart';
import 'package:relationship_manager/services/app_settings_service.dart';
import 'package:relationship_manager/services/auth_service.dart';
import 'package:relationship_manager/services/database_service.dart';

import '../../support/test_database.dart';

// Providers wrap the whole MaterialApp, not just `home`: showModalBottomSheet
// (used by both PlaceSheet.show and, from "Add story here", QuickAddSheet.show)
// pushes a new route as a sibling of `home` in the Navigator's Overlay, not
// as its descendant - a provider scoped inside `home` alone wouldn't be
// visible to that new route's content.
Widget _wrap(DatabaseService db, Widget child) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<DatabaseService>.value(value: db),
      ChangeNotifierProvider<AuthService>.value(value: AuthService()),
      ChangeNotifierProvider<AppSettingsService>(create: (_) => AppSettingsService()),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 2; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
}

void main() {
  testWidgets('shows the place name, and its stories in date order with their persons',
      (tester) async {
    late DatabaseService db;
    late Place place;
    late Person alice;
    await tester.runAsync(() async {
      db = createTestDatabaseService();
      await db.initialize();
      place = Place(name: 'The old bridge', latitude: 10, longitude: 10);
      await db.savePlace(place);
      alice = Person(name: 'Alice');
      await db.savePerson(alice);
      await db.saveEvent(Event(
        title: 'Later story',
        dateTime: DateTime(2020, 6),
        placeId: place.id,
        participantIds: [alice.id],
      ));
      await db.saveEvent(Event(
        title: 'Earlier story',
        dateTime: DateTime(1990, 1),
        placeId: place.id,
      ));
    });

    await tester.pumpWidget(_wrap(db, PlaceSheet(placeId: place.id)));
    await _settle(tester);

    expect(find.widgetWithText(TextField, 'The old bridge'), findsOneWidget);
    expect(find.text('Later story'), findsOneWidget);
    expect(find.text('Earlier story'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Alice'), findsOneWidget);

    // Date order: earliest first.
    final earlierCenter = tester.getCenter(find.text('Earlier story'));
    final laterCenter = tester.getCenter(find.text('Later story'));
    expect(earlierCenter.dy, lessThan(laterCenter.dy));
  });

  testWidgets('with no stories yet, says so', (tester) async {
    late DatabaseService db;
    late Place place;
    await tester.runAsync(() async {
      db = createTestDatabaseService();
      await db.initialize();
      place = Place(name: 'Empty spot', latitude: 1, longitude: 1);
      await db.savePlace(place);
    });

    await tester.pumpWidget(_wrap(db, PlaceSheet(placeId: place.id)));
    await _settle(tester);

    expect(find.text('No stories here yet.'), findsOneWidget);
  });

  testWidgets('editing the name and confirming saves it', (tester) async {
    late DatabaseService db;
    late Place place;
    await tester.runAsync(() async {
      db = createTestDatabaseService();
      await db.initialize();
      place = Place(name: 'Old name', latitude: 5, longitude: 5);
      await db.savePlace(place);
    });

    await tester.pumpWidget(_wrap(db, PlaceSheet(placeId: place.id)));
    await _settle(tester);

    final nameField = find.widgetWithText(TextField, 'Old name');
    await tester.enterText(nameField, 'New name');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);

    late Place? updated;
    await tester.runAsync(() async => updated = await db.getPlace(place.id));
    expect(updated!.name, 'New name');
  });

  testWidgets('"Add story here" opens the quick add sheet already bound to this place',
      (tester) async {
    late DatabaseService db;
    late Place place;
    await tester.runAsync(() async {
      db = createTestDatabaseService();
      await db.initialize();
      place = Place(name: 'Grandpa\'s workshop', latitude: 20, longitude: 20);
      await db.savePlace(place);
    });

    // Opening the form initializes its recorder even though this navigation
    // test never records. Fake only that platform lifecycle.
    const recorderChannel = MethodChannel('com.llfbandit.record/messages');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        recorderChannel, (call) async {
      expect(call.method, isIn(['create', 'dispose']));
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(recorderChannel, null));

    await tester.pumpWidget(_wrap(db, PlaceSheet(placeId: place.id)));
    await _settle(tester);

    // Not pumpAndSettle(): the place sheet's own small map keeps retrying
    // its (in this offline test) permanently-failing tile requests, so
    // there's always another frame scheduled and pumpAndSettle would never
    // return. Bounded plain pumps complete the sheet transition; the
    // database lookups need the real async zone below.
    await tester.tap(find.widgetWithText(FilledButton, 'Add story here'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // The form and person recognizer share SQLite's isolate transaction lock.
    // Await their lookup queue in the real async zone before ending the test.
    await tester.runAsync(() async {
      await db.getPersons();
      await db.getPlaces();
    });
    await tester.pump();

    // The quick add sheet opened already pinned to this place - its place
    // name field (distinct from the place sheet's own name field
    // underneath, which shows the same text) shows the place's name and
    // can't be edited to something else without explicitly clearing it
    // first.
    final placeNameField = tester.widget<TextField>(find.descendant(
      of: find.byType(QuickAddSheet),
      matching: find.widgetWithText(TextField, 'Grandpa\'s workshop'),
    ));
    expect(placeNameField.enabled, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => db.getPersons());
  });
}
