import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:relationship_manager/services/oidc/auth_transport.dart';
import 'package:relationship_manager/services/oidc/oidc_flow.dart';
import 'package:relationship_manager/services/oidc/oidc_native.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('crossingthestreams.io/flutter_appauth');
  late List<MethodCall> calls;
  var omitVerifier = false;
  setUp(() {
    calls = [];
    omitVerifier = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'authorize') {
        return {
          'authorizationCode': 'one-use',
          'codeVerifier': omitVerifier ? null : 'pkce',
          'nonce': 'nonce'
        };
      }
      if (call.method == 'token') {
        return {'accessToken': 'access', 'tokenType': 'Bearer'};
      }
      throw StateError('Unexpected SDK call ${call.method}');
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));
  test('native split exchange preserves SDK PKCE nonce and exact redirect',
      () async {
    final client = MockClient((_) async => http.Response('{}', 200));
    final token = await authCompletion(() => beginOidcLogin(
        const OidcConfig('https://app.rfind.de/auth/realms/con', 'con-app'),
        'de',
        client));
    expect(token, 'access');
    expect(calls.map((x) => x.method), ['authorize', 'token']);
    expect((calls.first.arguments as Map)['additionalParameters'],
        {'ui_locales': 'de'});
    final request = calls.last.arguments as Map;
    expect(request['authorizationCode'], 'one-use');
    expect(request['codeVerifier'], 'pkce');
    expect(request['nonce'], 'nonce');
    expect(request['redirectUrl'], 'com.coflnet.con:/oauthredirect');
  });
  test('native account creation uses the SDK registration prompt with PKCE',
      () async {
    await authCompletion(() => beginOidcLogin(
        const OidcConfig('https://auth.coflnet.com/auth/realms/con', 'con-app',
            createAccount: true),
        'de',
        MockClient((_) async => http.Response('{}', 200))));
    final request = calls.first.arguments as Map;
    expect(request['promptValues'], ['create']);
    expect((calls.last.arguments as Map)['codeVerifier'], 'pkce');
  });
  test('native missing verifier cannot exchange or replay a code', () async {
    omitVerifier = true;
    await expectLater(
        authCompletion(() => beginOidcLogin(
            const OidcConfig('https://app.rfind.de/auth/realms/con', 'con-app'),
            'en',
            MockClient((_) async => http.Response('{}', 200)))),
        throwsFormatException);
    expect(calls.map((x) => x.method), ['authorize']);
  });

  for (final provider in ['', 'google', 'another-provider']) {
    test('native provider "$provider" keeps SDK PKCE and nonce', () async {
      final token = await authCompletion(() => beginOidcLogin(
          OidcConfig('https://auth.coflnet.com/auth/realms/con', 'con-app',
              createAccount: true, identityProvider: provider),
          'en',
          MockClient((_) async => http.Response('{}', 200))));
      expect(token, 'access');
      final request = calls.first.arguments as Map;
      expect(request['additionalParameters'],
          {'ui_locales': 'en', 'kc_idp_hint': provider});
      expect(request['promptValues'], provider.isEmpty ? ['create'] : null);
      final exchange = calls.last.arguments as Map;
      expect(exchange['codeVerifier'], 'pkce');
      expect(exchange['nonce'], 'nonce');
      expect(exchange['redirectUrl'], 'com.coflnet.con:/oauthredirect');
    });
  }
}
