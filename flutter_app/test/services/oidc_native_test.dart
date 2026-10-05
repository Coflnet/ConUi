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
    final request = calls.last.arguments as Map;
    expect(request['authorizationCode'], 'one-use');
    expect(request['codeVerifier'], 'pkce');
    expect(request['nonce'], 'nonce');
    expect(request['redirectUrl'], 'com.coflnet.con:/oauthredirect');
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
}
