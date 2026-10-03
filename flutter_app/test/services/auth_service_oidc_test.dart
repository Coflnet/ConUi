import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/services/auth_service.dart';
import '../support/test_database.dart';

String _token(String userId) =>
    'header.${base64UrlEncode(utf8.encode(jsonEncode({
          'sub': userId
        })))}.signature';
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  http.Client backend(
          {bool rejectMe = false, bool enabled = true, String? meBody}) =>
      MockClient((request) async {
        switch (request.url.path) {
          case '/api/auth/config':
            return http.Response(
                jsonEncode({
                  'enabled': enabled,
                  'issuer': 'https://app.rfind.de/auth/realms/con',
                  'clientId': 'con-app'
                }),
                200);
          case '/api/auth/oidc':
            expect(jsonDecode(request.body)['accessToken'], 'access');
            return http.Response(jsonEncode({'authToken': _token('u1')}), 200);
          case '/api/auth/me':
            expect(request.headers['Authorization'], 'Bearer ${_token('u1')}');
            return http.Response(
                meBody ?? '{"id":"u1","encryptionKeySalt":"server-salt"}',
                rejectMe ? 503 : 200);
          default:
            throw StateError('Unexpected request ${request.url.path}');
        }
      });
  test(
      'native sign-in verifies account/salt while keeping local stories and pending edits',
      () async {
    final db = createTestDatabaseService();
    await db.initialize();
    final story = Event(title: 'Local story', dateTime: DateTime(2020));
    await db.saveEvent(story);
    final auth = AuthService(
        httpClient: backend(),
        beginSignIn: (config, locale, _) async {
          expect(config.clientId, 'con-app');
          expect(locale, 'de');
          return 'access';
        });
    await auth.initialize();
    await auth.continueWithoutAccount();
    expect(await auth.signIn(), isTrue);
    expect(auth.userId, 'u1');
    expect(auth.encryptionSalt, 'server-salt');
    expect(auth.continuedWithoutAccount, isFalse);
    expect((await db.getEvent(story.id))!.title, 'Local story');
    expect(await db.getPendingChanges(), hasLength(1));
  });
  test('web callback completes during initialize even in remembered local mode',
      () async {
    SharedPreferences.setMockInitialValues({'continued_without_account': true});
    final auth =
        AuthService(httpClient: backend(), finishSignIn: (_) async => 'access');
    await auth.initialize();
    expect(auth.isAuthenticated, isTrue);
    expect(auth.encryptionSalt, 'server-salt');
    expect(auth.continuedWithoutAccount, isFalse);
  });
  test(
      'failed account verification does not adopt token or replace previous identity salt',
      () async {
    SharedPreferences.setMockInitialValues({
      'auth_token': _token('old'),
      'user_id': 'old',
      'encryption_salt': 'old-salt'
    });
    final auth = AuthService(
        httpClient: backend(rejectMe: true),
        beginSignIn: (_, __, ___) async => 'access');
    await auth.initialize();
    expect(await auth.signIn(), isFalse);
    expect(auth.signInFailed, isTrue);
    expect(auth.userId, 'old');
    expect(auth.encryptionSalt, 'old-salt');
    expect(auth.token, _token('old'));
  });
  for (final body in [
    '{}',
    '{"id":"u1"}',
    '{"id":"other","encryptionKeySalt":"salt"}',
    'not-json'
  ]) {
    test(
        'malformed or mismatched account response preserves previous identity: $body',
        () async {
      SharedPreferences.setMockInitialValues({
        'auth_token': _token('old'),
        'user_id': 'old',
        'encryption_salt': 'old-salt'
      });
      final auth = AuthService(
          httpClient: backend(meBody: body),
          beginSignIn: (_, __, ___) async => 'access');
      await auth.initialize();
      expect(await auth.signIn(), isFalse);
      expect(auth.signInFailed, isTrue);
      expect(auth.token, _token('old'));
      expect(auth.userId, 'old');
      expect(auth.encryptionSalt, 'old-salt');
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString('encryption_salt'), 'old-salt');
    });
  }
  test('unavailable config keeps local mode and never opens identity browser',
      () async {
    final auth = AuthService(
        httpClient: backend(enabled: false),
        beginSignIn: (_, __, ___) async => throw StateError('must not launch'));
    await auth.initialize();
    await auth.continueWithoutAccount();
    expect(await auth.signIn(), isFalse);
    expect(auth.signInUnavailable, isTrue);
    expect(auth.continuedWithoutAccount, isTrue);
    expect(auth.isAuthenticated, isFalse);
  });
  test('callback rejection remains visible until local action clears the error',
      () async {
    SharedPreferences.setMockInitialValues({'continued_without_account': true});
    final auth = AuthService(
        finishSignIn: (_) async =>
            throw const FormatException('Invalid state'));
    await auth.initialize();
    expect(auth.signInFailed, isTrue);
    expect(auth.isAuthenticated, isFalse);
    await auth.continueWithoutAccount();
    expect(auth.signInFailed, isFalse);
    expect(auth.continuedWithoutAccount, isTrue);
  });
}
