// Regression tests for "Continue without account": the app must be usable
// for recording and local data without signing in, and that choice must be
// remembered across restarts (a fresh AuthService + initialize(), the same
// way the app starts up for real).
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:relationship_manager/services/auth_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('continueWithoutAccount is remembered across a restart', () async {
    final first = AuthService();
    await first.initialize();
    expect(first.continuedWithoutAccount, isFalse);

    await first.continueWithoutAccount();
    expect(first.continuedWithoutAccount, isTrue);
    expect(first.isAuthenticated, isFalse);

    // Simulate an app restart: a brand new AuthService reading the same
    // SharedPreferences-backed storage.
    final second = AuthService();
    await second.initialize();
    expect(second.continuedWithoutAccount, isTrue);
  });

  test('logout clears continuedWithoutAccount', () async {
    final auth = AuthService();
    await auth.initialize();
    await auth.continueWithoutAccount();
    expect(auth.continuedWithoutAccount, isTrue);

    await auth.logout();

    expect(auth.continuedWithoutAccount, isFalse);
  });
}
