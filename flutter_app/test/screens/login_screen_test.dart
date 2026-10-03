// Widget-level regression test for "Continue without account": tapping the
// button on the login screen must be enough to record that choice, without
// any sign-in.
//
// Pumps LoginScreen directly (not the full RelationshipManagerApp): once
// continuedWithoutAccount flips, main.dart's root routing swaps in
// HomeScreen, whose child screens immediately query the real (FFI-backed)
// database - and sqflite_common_ffi's isolate synchronization doesn't
// resolve inside testWidgets' FakeAsync zone (see widget_test.dart's
// runAsync note), so mounting HomeScreen here would deadlock the test.
// main.dart's routing itself is a one-line condition on
// continuedWithoutAccount, which this test does verify.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:relationship_manager/screens/login_screen.dart';
import 'package:relationship_manager/services/auth_service.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/sync_service.dart';

import '../support/localized_app.dart';
import '../support/test_database.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('tapping "Continue without account" records the choice',
      (tester) async {
    late DatabaseService dbService;
    late AuthService authService;
    await tester.runAsync(() async {
      dbService = createTestDatabaseService();
      await dbService.initialize();
      authService = AuthService(
        httpClient: MockClient((request) async => http.Response('{}', 404)),
      );
      await authService.initialize();
    });

    final syncService = SyncService(dbService, authService);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: dbService),
          ChangeNotifierProvider.value(value: authService),
          ChangeNotifierProvider.value(value: syncService),
        ],
        child: wrapLocalized(const LoginScreen()),
      ),
    );

    // Flush the debug auto-login timer (see widget_test.dart for why not
    // pumpAndSettle) before it can race with the tap below.
    await tester.pump(const Duration(milliseconds: 600));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(find.textContaining('Login failed'), findsOneWidget);
    expect(authService.continuedWithoutAccount, isFalse);
    final signInButton = find.byKey(const Key('account-sign-in'));
    await tester.ensureVisible(signInButton);
    await tester.tap(signInButton);
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(authService.signInUnavailable, isTrue);
    expect(find.textContaining('Account sign-in is currently unavailable'),
        findsOneWidget);

    final continueButton = find.text('Continue without account');
    await tester.ensureVisible(continueButton);
    await tester.pump();
    await tester.tap(continueButton);
    await tester.pump();
    await tester.pump();

    expect(authService.continuedWithoutAccount, isTrue);
    expect(syncService.needsSignIn, isTrue);
  });

  testWidgets('shows German text with a German device locale', (tester) async {
    late DatabaseService dbService;
    late AuthService authService;
    await tester.runAsync(() async {
      dbService = createTestDatabaseService();
      await dbService.initialize();
      authService = AuthService(
        httpClient: MockClient((request) async => http.Response('{}', 404)),
      );
      await authService.initialize();
    });
    final syncService = SyncService(dbService, authService);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: dbService),
          ChangeNotifierProvider.value(value: authService),
          ChangeNotifierProvider.value(value: syncService),
        ],
        child: wrapLocalized(const LoginScreen(), locale: const Locale('de')),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }

    expect(find.text('Ohne Konto fortfahren'), findsOneWidget);
    expect(find.text('Entwicklungs-Anmeldung'), findsOneWidget);
    expect(find.textContaining('Anmeldung fehlgeschlagen'), findsOneWidget);
    // Nothing from the English strings must leak through.
    expect(find.text('Continue without account'), findsNothing);
    expect(find.text('Development Login'), findsNothing);
  });
}
