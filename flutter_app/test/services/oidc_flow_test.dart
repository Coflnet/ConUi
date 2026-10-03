import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relationship_manager/services/oidc/oidc_flow.dart';

void main() {
  const issuer = 'https://app.rfind.de/auth/realms/con';
  late OidcWebFlow flow;
  late String url;
  String? stored;
  String? navigated;
  late DateTime now;
  late int requests;
  late http.Client client;
  setUp(() {
    url = 'https://con.coflnet.com/';
    stored = null;
    navigated = null;
    now = DateTime(2026, 10, 3);
    requests = 0;
    flow = OidcWebFlow(
        currentUrl: () => url,
        readSession: () => stored,
        writeSession: (value) => stored = value,
        clearSession: () => stored = null,
        navigate: (value) => navigated = value,
        replaceUrl: (value) => url = value,
        now: () => now);
    client = MockClient((request) async {
      requests++;
      expect(stored, isNull, reason: 'consume before token exchange');
      expect(url, 'https://con.coflnet.com/');
      return http.Response('{"access_token":"idp-token"}', 200);
    });
  });
  Future<String> callback() async {
    await flow.login(const OidcConfig(issuer, 'con-app'), 'de');
    final authorize = Uri.parse(navigated!);
    final session = jsonDecode(stored!);
    expect(authorize.queryParameters['code_challenge_method'], 'S256');
    expect(
        authorize.queryParameters['code_challenge'],
        base64UrlEncode(sha256.convert(utf8.encode(session['verifier'])).bytes)
            .replaceAll('=', ''));
    expect(session['verifier'].length, 43);
    expect(authorize.queryParameters['ui_locales'], 'de');
    return 'https://con.coflnet.com/?code=one-use&state=${session['state']}&iss=${Uri.encodeComponent(issuer)}';
  }

  test(
      'PKCE callback exchanges once and clears callback data before the request',
      () async {
    final originalCallback = await callback();
    url = originalCallback;
    expect(await flow.finish(client), 'idp-token');
    expect(requests, 1);
    url = originalCallback;
    await expectLater(flow.finish(client), throwsFormatException);
    expect(requests, 1);
  });
  test('wrong state consumes the session without exchanging', () async {
    url = (await callback()).replaceFirst('state=', 'state=wrong');
    await expectLater(flow.finish(client), throwsFormatException);
    expect(stored, isNull);
    expect(requests, 0);
  });
  test('expired transaction cannot be replayed', () async {
    url = await callback();
    now = now.add(const Duration(minutes: 11));
    await expectLater(flow.finish(client), throwsFormatException);
    expect(stored, isNull);
    expect(requests, 0);
  });
  test('wrong callback origin and issuer are refused', () async {
    url = (await callback())
        .replaceFirst('https://con.coflnet.com', 'https://other.example');
    await expectLater(flow.finish(client), throwsFormatException);
    url = (await callback()).replaceFirst(Uri.encodeComponent(issuer),
        Uri.encodeComponent('https://other.example'));
    await expectLater(flow.finish(client), throwsFormatException);
    expect(requests, 0);
  });
  test('denied login and failed token exchange clean up for a retry', () async {
    url =
        (await callback()).replaceFirst('code=one-use', 'error=access_denied');
    await expectLater(flow.finish(client), throwsFormatException);
    expect(stored, isNull);
    url = await callback();
    await expectLater(
        flow.finish(MockClient((_) async => http.Response('{}', 503))),
        throwsFormatException);
    expect(stored, isNull);
    expect(url, 'https://con.coflnet.com/');
  });
  test('no callback leaves local startup and pending state untouched',
      () async {
    await flow.login(const OidcConfig(issuer, 'con-app'), 'en');
    final pending = stored;
    expect(await flow.finish(client), isNull);
    expect(stored, pending);
    expect(requests, 0);
  });
  test('insecure review flag permits only exact loopback hosts', () {
    for (final host in ['localhost', '127.0.0.1', '[::1]']) {
      final config = {
        'enabled': true,
        'issuer': 'http://$host:18780/realms/con',
        'clientId': 'con-app'
      };
      if (allowInsecureLocalOidc) {
        expect(OidcConfig.fromJson(config).allowInsecureConnections, isTrue);
      } else {
        expect(() => OidcConfig.fromJson(config), throwsFormatException);
      }
    }
    for (final host in ['localhost.example', '127.0.0.2', 'remote.example']) {
      expect(
          () => OidcConfig.fromJson({
                'enabled': true,
                'issuer': 'http://$host:18780/realms/con',
                'clientId': 'con-app'
              }),
          throwsFormatException);
    }
  });
  test(
      'config forbids remote HTTP, credentials, unexpected clients and altered issuer URLs',
      () {
    for (final value in [
      'http://remote.example/realms/con',
      'https://user:password@id.example/realms/con',
      '$issuer/',
      '$issuer?other=1'
    ]) {
      expect(
          () => OidcConfig.fromJson(
              {'enabled': true, 'issuer': value, 'clientId': 'con-app'}),
          throwsFormatException);
    }
    expect(
        () => OidcConfig.fromJson(
            {'enabled': true, 'issuer': issuer, 'clientId': 'other-app'}),
        throwsFormatException);
    if (!allowInsecureLocalOidc) {
      expect(
          () => OidcConfig.fromJson({
                'enabled': true,
                'issuer': 'http://127.0.0.1:18780/realms/con',
                'clientId': 'con-app'
              }),
          throwsFormatException);
    }
  });
}
