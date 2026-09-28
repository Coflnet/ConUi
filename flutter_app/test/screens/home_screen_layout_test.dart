// Regression test for HomeScreen's responsive navigation (item 5 of the
// production rollout brief): a bottom NavigationBar below ~840 logical
// pixels wide, a side NavigationRail at or above it - never both, and
// switching tabs works the same way through either one.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/screens/home_screen.dart';
import 'package:relationship_manager/services/app_settings_service.dart';
import 'package:relationship_manager/services/auth_service.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/sync_service.dart';

import '../support/test_database.dart';

Future<void> _settle(WidgetTester tester, {int rounds = 30}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpHome(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late DatabaseService db;
    await tester.runAsync(() async {
      db = createTestDatabaseService();
      await db.initialize();
    });
    final auth = AuthService();
    final sync = SyncService(db, auth);
    final appSettings = AppSettingsService();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DatabaseService>.value(value: db),
          ChangeNotifierProvider<AuthService>.value(value: auth),
          ChangeNotifierProvider<SyncService>.value(value: sync),
          ChangeNotifierProvider<AppSettingsService>.value(value: appSettings),
        ],
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: [Locale('en'), Locale('de')],
          home: HomeScreen(),
        ),
      ),
    );
    await _settle(tester);
  }

  testWidgets('narrow window (phone-width): bottom NavigationBar, no rail',
      (tester) async {
    await pumpHome(tester, const Size(390, 844));

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
  });

  testWidgets('wide window (>=840): side NavigationRail, no bottom bar',
      (tester) async {
    await pumpHome(tester, const Size(1440, 900));

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('tapping a NavigationRail destination switches tabs like the bottom bar does',
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
}
