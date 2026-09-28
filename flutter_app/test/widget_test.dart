// Smoke test that wires up the real widget tree with test doubles for the
// services that would otherwise touch the filesystem or the network:
// - an in-memory database (see test/support/test_database.dart)
// - a mocked http.Client so AuthService never dials out
//
// This replaces the counter-app template test, which didn't even compile
// against this app.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:relationship_manager/main.dart';
import 'package:relationship_manager/services/app_settings_service.dart';
import 'package:relationship_manager/services/auth_service.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/sync_service.dart';

import 'support/test_database.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('boots to the login screen and wires up providers',
      (tester) async {
    // sqflite_common_ffi talks to a background isolate for real, which
    // doesn't resolve inside testWidgets' FakeAsync zone (it would hang
    // forever waiting for a message that only arrives on the real event
    // loop). runAsync() steps outside FakeAsync for just this setup.
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
    final appSettings = AppSettingsService();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: dbService),
          ChangeNotifierProvider.value(value: authService),
          ChangeNotifierProvider.value(value: syncService),
          ChangeNotifierProvider.value(value: appSettings),
        ],
        child: const RelationshipManagerApp(),
      ),
    );

    expect(find.text('Relationship Manager'), findsOneWidget);
    expect(find.text('Login'), findsOneWidget);
    expect(dbService.isInitialized, isTrue);
    expect(authService.isAuthenticated, isFalse);

    // The login screen auto-logs in after a 500ms delay in debug mode.
    // Flush that timer and the (mocked, failing) network round trip so no
    // timers are left pending when the test ends. Deliberately NOT using
    // pumpAndSettle: while `_isLoading` is true the screen shows an
    // indeterminate CircularProgressIndicator, whose animation never
    // "settles", which would hang pumpAndSettle forever.
    await tester.pump(const Duration(milliseconds: 600));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }

    expect(find.textContaining('Login failed'), findsOneWidget);
  });
}
