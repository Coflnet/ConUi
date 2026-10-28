// Smoke test that wires up the real widget tree with test doubles for the
// services that would otherwise touch the filesystem or the network:
// - an in-memory database (see test/support/test_database.dart)
// - a mocked http.Client so AuthService never dials out
//
// This replaces the counter-app template test, which didn't even compile
// against this app.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:relationship_manager/main.dart';
import 'package:relationship_manager/screens/home_screen.dart';
import 'package:relationship_manager/screens/login_screen.dart';
import 'package:relationship_manager/services/app_settings_service.dart';
import 'package:relationship_manager/services/auth_service.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/sync_service.dart';

import 'support/test_database.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('fresh launch opens local home without any sign-in request',
      (tester) async {
    late DatabaseService db;
    late AuthService auth;
    var requests = 0;
    await tester.runAsync(() async {
      db = createTestDatabaseService();
      await db.initialize();
      auth = AuthService(
        httpClient: MockClient((_) async {
          requests++;
          return http.Response('{}', 404);
        }),
      );
      await auth.initialize();
    });
    addTearDown(auth.dispose);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<DatabaseService>.value(value: db),
        ChangeNotifierProvider<AuthService>.value(value: auth),
        ChangeNotifierProvider<SyncService>(
            create: (_) => SyncService(db, auth)),
        ChangeNotifierProvider<AppSettingsService>(
            create: (_) => AppSettingsService()),
      ],
      child: const RelationshipManagerApp(),
    ));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(LoginScreen), findsNothing);
    expect(find.text('Your stories. No account needed.'), findsOneWidget);
    expect(find.text('Create your first story'), findsOneWidget);
    expect(auth.isAuthenticated, isFalse);
    expect(auth.continuedWithoutAccount, isFalse,
        reason: 'opening the app must not require an earlier guest choice');
    expect(requests, 0, reason: 'do not begin authentication on first launch');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('failed account sign-in keeps the remembered guest home mounted',
      (tester) async {
    late DatabaseService db;
    late AuthService auth;
    await tester.runAsync(() async {
      db = createTestDatabaseService();
      await db.initialize();
      auth = AuthService(
        httpClient: MockClient((_) async => http.Response(
            '{"enabled":true,"issuer":"https://auth.coflnet.com/auth/realms/con","clientId":"con-app"}',
            200)),
        beginSignIn: (_, __, ___) async =>
            throw const FormatException('cancelled'),
      );
      await auth.continueWithoutAccount();
    });
    addTearDown(auth.dispose);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<DatabaseService>.value(value: db),
        ChangeNotifierProvider<AuthService>.value(value: auth),
        ChangeNotifierProvider<SyncService>(
            create: (_) => SyncService(db, auth)),
        ChangeNotifierProvider<AppSettingsService>(
            create: (_) => AppSettingsService()),
      ],
      child: const RelationshipManagerApp(),
    ));
    final home = tester.state(find.byType(HomeScreen));
    await tester.runAsync(() async => expect(await auth.signIn(), isFalse));
    await tester.pump();
    expect(auth.signInFailed, isTrue);
    expect(find.textContaining('Sign-in could not be completed'), findsOneWidget);
    expect(find.byType(LoginScreen), findsNothing);
    expect(tester.state(find.byType(HomeScreen)), same(home));
    await tester.runAsync(() async {
      await db.getEvents();
      await db.getPlaces();
      await db.getPersons();
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
