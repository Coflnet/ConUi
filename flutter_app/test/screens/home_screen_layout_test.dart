// Regression test for HomeScreen's responsive navigation (item 5 of the
// production rollout brief): a bottom NavigationBar below ~840 logical
// pixels wide, a side NavigationRail at or above it - never both, and
// switching tabs works the same way through either one.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/screens/home_screen.dart';
import 'package:relationship_manager/screens/events/add_event_screen.dart';
import 'package:relationship_manager/screens/places/place_sheet.dart';
import 'package:relationship_manager/screens/quick_add/quick_add_sheet.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/screens/persons/persons_screen.dart';
import 'package:relationship_manager/services/app_settings_service.dart';
import 'package:relationship_manager/services/auth_service.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/sync_service.dart';

import '../support/test_database.dart';

Future<void> _settle(WidgetTester tester, {int rounds = 30}) async {
  for (var i = 0; i < rounds; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpHome(WidgetTester tester, Size size,
      {bool signIn = false, bool password = false, bool reducedMotion = false,
       Future<void> Function(DatabaseService)? seed}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late DatabaseService db;
    await tester.runAsync(() async {
      db = createTestDatabaseService();
      await db.initialize();
      await seed?.call(db);
    });
    if (signIn) {
      SharedPreferences.setMockInitialValues(
          {'auth_token': 'fake.token.value', 'user_id': 'u1'});
    }
    final auth = AuthService(
        httpClient: MockClient((_) async => http.Response('{}', 503)));
    await tester.runAsync(auth.initialize);
    final sync = SyncService(db, auth);
    if (password) {
      await tester.runAsync(() => sync.initializeEncryption('password'));
    }
    final appSettings = AppSettingsService();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DatabaseService>.value(value: db),
          ChangeNotifierProvider<AuthService>.value(value: auth),
          ChangeNotifierProvider<SyncService>.value(value: sync),
          ChangeNotifierProvider<AppSettingsService>.value(value: appSettings),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
            child: child!,
          ),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: const [Locale('en'), Locale('de')],
          home: const HomeScreen(),
        ),
      ),
    );
    await _settle(tester);
  }

  for (final kind in ['place', 'object']) {
    testWidgets('search opens the matched $kind instead of only switching tabs', (tester) async {
      await pumpHome(tester, const Size(390, 844), seed: (db) async {
        if (kind == 'place') {
          await db.savePlace(Place(id: 'matched-place', name: 'Unique match', latitude: 50, longitude: 10));
        } else {
          await db.saveObject(EventObject(id: 'matched-object', name: 'Unique match', description: 'Object detail content'));
        }
      });
      await tester.tap(find.byIcon(Icons.search));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'Unique match');
      await _settle(tester);
      await tester.tap(find.widgetWithText(ListTile, 'Unique match'));
      await _settle(tester);
      if (kind == 'place') {
        expect(tester.widget<PlaceSheet>(find.byType(PlaceSheet)).placeId, 'matched-place');
      } else {
        expect(find.descendant(of: find.byType(BottomSheet), matching: find.text('Object detail content')), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Close'), findsOneWidget);
        expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, lessThan(4));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('narrow window (phone-width): bottom NavigationBar, no rail',
      (tester) async {
    await pumpHome(tester, const Size(390, 844));

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).destinations
        .map((destination) => (destination as NavigationDestination).label),
        ['Map', 'People', 'Stories', 'Places']);
  });

  testWidgets(
      'guest introduction opens a first story with no required location',
      (tester) async {
    const recorderChannel = MethodChannel('com.llfbandit.record/messages');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        recorderChannel, (call) async {
      expect(call.method, isIn(['create', 'dispose']));
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(recorderChannel, null));
    await pumpHome(tester, const Size(390, 844));
    expect(find.text('Your stories. No account needed.'), findsOneWidget);
    await tester.tap(find.text('Create your first story'));
    await _settle(tester);
    expect(find.byType(AddEventScreen), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Continue with Google'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('returning guests keep their stories instead of another welcome',
      (tester) async {
    await pumpHome(tester, const Size(390, 844), seed: (db) async {
      await db
          .saveEvent(Event(title: 'Remember this', dateTime: DateTime(2026)));
    });
    expect(find.text('Your stories. No account needed.'), findsNothing);
    await tester.tap(find.descendant(
        of: find.byType(NavigationBar), matching: find.text('Stories')));
    await _settle(tester);
    expect(find.textContaining('2026'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('wide window (>=840): side NavigationRail, no bottom bar',
      (tester) async {
    await pumpHome(tester, const Size(1440, 900));

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(tester.widget<NavigationRail>(find.byType(NavigationRail)).destinations
        .map((destination) => (destination.label as Text).data),
        ['Map', 'People', 'Stories', 'Places']);
    expect(find.text('Last used place'), findsNothing);
  });

  testWidgets('desktop shortcut reuses the last saved story place, not its historical date',
      (tester) async {
    const recorderChannel = MethodChannel('com.llfbandit.record/messages');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        recorderChannel, (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(recorderChannel, null));
    await http.runWithClient(() async {
      late DatabaseService database;
      await pumpHome(tester, const Size(1440, 900), seed: (db) async {
        database = db;
        for (final id in ['earlier', 'recent', 'deleted']) {
          await db.savePlace(Place(id: id, name: '$id place', latitude: 50,
              longitude: 10, isDeleted: id == 'deleted'));
        }
        await db.saveEvent(Event(title: 'Earlier save', dateTime: DateTime(2026),
            placeId: 'earlier', updatedAt: DateTime(2026, 1)));
        await db.saveEvent(Event(title: 'Historical story saved later', dateTime: DateTime(1952),
            placeId: 'recent', updatedAt: DateTime(2026, 2)));
        await db.saveEvent(Event(title: 'Deleted place', dateTime: DateTime(2026),
            placeId: 'deleted', updatedAt: DateTime(2026, 3)));
        await db.saveEvent(Event(title: 'No place', dateTime: DateTime(2026),
            updatedAt: DateTime(2026, 4)));
      });
      final shortcut = find.widgetWithText(OutlinedButton, 'recent place');
      expect(find.text('Last used place'), findsOneWidget);
      expect(shortcut, findsOneWidget);
      await tester.tap(shortcut);
      await _settle(tester);
      final sheet = tester.widget<QuickAddSheet>(find.byType(QuickAddSheet));
      expect(sheet.initialPlace?.id, 'recent');
      expect(sheet.position.value.latitude, 50);
      expect(sheet.position.value.longitude, 10);
      await tester.enterText(find.widgetWithText(TextField, 'What happened here?'),
          'Another memory at the same place.');
      await _settle(tester);
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save story'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final Function save = tester.widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Save story')).onPressed!;
        final dynamic result = save();
        if (result is Future) await result;
      });
      await _settle(tester);
      await tester.pumpAndSettle();
      expect((await tester.runAsync(database.getEvents))!
          .where((event) => event.placeId == 'recent'), hasLength(2));
      expect(find.byType(QuickAddSheet), findsNothing);
      expect(await tester.runAsync(database.getLastStoryPlace),
          isA<Place>().having((place) => place.id, 'id', 'recent'));
      tester.view.physicalSize = const Size(390, 844);
      await _settle(tester);
      expect(find.text('Last used place'), findsNothing);
      tester.view.physicalSize = const Size(840, 400);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _settle(tester);
      await tester.ensureVisible(shortcut);
      await tester.pumpAndSettle();
      await tester.tap(shortcut);
      await _settle(tester);
      expect(tester.widget<QuickAddSheet>(find.byType(QuickAddSheet)).initialPlace?.id,
          'recent');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, () => MockClient((request) async => request.url.host == 'photon.komoot.io'
        ? http.Response('{"features":[]}', 200)
        : http.Response.bytes(base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='),
            200, headers: {'content-type': 'image/png'})));
  });

  testWidgets(
      'tapping a NavigationRail destination switches tabs like the bottom bar does',
      (tester) async {
    await pumpHome(tester, const Size(1440, 900));

    // Starts on Map; PersonsScreen isn't built as the active tab's content
    // yet (IndexedStack keeps it in the tree but AppBar title reflects the
    // selected tab either way).
    expect(find.text('Map'), findsWidgets); // AppBar title + rail label

    await tester.tap(find.descendant(
      of: find.byType(NavigationRail),
      matching: find.text('People'),
    ));
    await _settle(tester);

    expect(find.text('People'), findsWidgets); // AppBar title now "People"
  });
  testWidgets('tab fades retain the same people view and its search state', (tester) async {
    await pumpHome(tester, const Size(390, 844));
    Future<void> select(String label) async {
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
      await tester.pump();
    }
    await select('People');
    final fadeFinder = find.ancestor(of: find.byType(IndexedStack), matching: find.byType(FadeTransition)).first;
    expect(tester.widget<FadeTransition>(fadeFinder).opacity.value, lessThan(1));
    await tester.pump(const Duration(milliseconds: 200));
    await _settle(tester);
    final peopleState = tester.state(find.byType(PersonsScreen));
    await tester.enterText(find.byType(TextField), 'Remember this search');
    await select('Stories');
    await tester.pump(const Duration(milliseconds: 200));
    await select('People');
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.state(find.byType(PersonsScreen)), same(peopleState));
    expect(find.text('Remember this search'), findsOneWidget);
    await select('People');
    expect(tester.widget<FadeTransition>(fadeFinder).opacity.value, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion switches tabs immediately without fading', (tester) async {
    await pumpHome(tester, const Size(390, 844), reducedMotion: true);
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('People')));
    await tester.pump();
    final fade = tester.widget<FadeTransition>(find.ancestor(
      of: find.byType(IndexedStack), matching: find.byType(FadeTransition),
    ).first);
    expect(fade.opacity.value, 1);
    expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('offline sync explains that an account is needed',
      (tester) async {
    await pumpHome(tester, const Size(390, 844));
    await tester.tap(find.byTooltip('Sync now'));
    await _settle(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Account required'), findsOneWidget);
    expect(find.text('Create an account with email'), findsOneWidget);
    expect(find.text('Sync complete'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await _settle(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('locked sync asks for encryption password', (tester) async {
    await pumpHome(tester, const Size(390, 844), signIn: true);
    await tester.tap(find.byTooltip('Sync now'));
    await _settle(tester);
    expect(find.text('Unlock encrypted sync'), findsOneWidget);
    expect(find.byType(TextFormField), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await _settle(tester);
    expect(find.text('Sync complete'), findsNothing);
  });

  testWidgets(
      'failed sync explains recovery without technical details or success',
      (tester) async {
    await pumpHome(tester, const Size(390, 844), signIn: true, password: true);
    await tester.tap(find.byTooltip('Sync now'));
    await _settle(tester);
    expect(
        find.textContaining(
            'Could not sync. Check your internet connection and try Sync now again.'),
        findsWidgets);
    expect(find.textContaining('503'), findsNothing);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.text('Sync complete'), findsNothing);
  });
  testWidgets('opening another route has no duplicate Hero tags',
      (tester) async {
    await pumpHome(tester, const Size(390, 844));
    Navigator.of(tester.element(find.byType(HomeScreen))).push(
      MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('New page'))),
    );
    await _settle(tester);
    expect(find.text('New page'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
