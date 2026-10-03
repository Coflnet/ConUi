import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

const allowInsecureLocalOidc =
    bool.fromEnvironment('ALLOW_INSECURE_LOCAL_OIDC');

class OidcConfig {
  final String issuer;
  final String clientId;
  const OidcConfig(this.issuer, this.clientId);
  bool get allowInsecureConnections =>
      allowInsecureLocalOidc &&
      Uri.parse(issuer).scheme == 'http' &&
      ['127.0.0.1', 'localhost', '::1'].contains(Uri.parse(issuer).host);

  factory OidcConfig.fromJson(Map<String, dynamic> json) {
    final issuer = Uri.parse(json['issuer'] as String);
    if (json['enabled'] != true ||
        !(issuer.scheme == 'https' ||
            (allowInsecureLocalOidc &&
                issuer.scheme == 'http' &&
                ['127.0.0.1', 'localhost', '::1'].contains(issuer.host))) ||
        issuer.host.isEmpty ||
        issuer.userInfo.isNotEmpty ||
        issuer.hasQuery ||
        issuer.hasFragment ||
        issuer.toString().endsWith('/') ||
        json['clientId'] != 'con-app') {
      throw const FormatException('Sign-in configuration unavailable');
    }
    return OidcConfig(issuer.toString(), json['clientId']);
  }
}

/// Per-tab PKCE transaction. Consume before any network request, including a
/// rejected callback, so replay and parallel callbacks cannot reuse a code.
class OidcWebFlow {
  final String Function() currentUrl;
  final String? Function() readSession;
  final void Function(String) writeSession;
  final void Function() clearSession;
  final void Function(String) navigate;
  final void Function(String) replaceUrl;
  final DateTime Function() now;
  OidcWebFlow(
      {required this.currentUrl,
      required this.readSession,
      required this.writeSession,
      required this.clearSession,
      required this.navigate,
      required this.replaceUrl,
      DateTime Function()? now})
      : now = now ?? DateTime.now;

  String _random() =>
      base64UrlEncode(List.generate(32, (_) => Random.secure().nextInt(256)))
          .replaceAll('=', '');

  Future<String?> login(OidcConfig config, String locale) async {
    final verifier = _random(), state = _random();
    final redirect = '${Uri.parse(currentUrl()).origin}/';
    writeSession(jsonEncode({
      'issuer': config.issuer,
      'clientId': config.clientId,
      'verifier': verifier,
      'state': state,
      'redirect': redirect,
      'created': now().millisecondsSinceEpoch
    }));
    navigate(Uri.parse('${config.issuer}/protocol/openid-connect/auth')
        .replace(queryParameters: {
      'client_id': config.clientId,
      'redirect_uri': redirect,
      'response_type': 'code',
      'scope': 'openid profile',
      'ui_locales': locale,
      'state': state,
      'code_challenge_method': 'S256',
      'code_challenge':
          base64UrlEncode(sha256.convert(utf8.encode(verifier)).bytes)
              .replaceAll('=', ''),
    }).toString());
    return null; // Navigation resumes through finish() after the callback.
  }

  Future<String?> finish(http.Client client) async {
    final callback = Uri.parse(currentUrl());
    if (!callback.queryParameters.containsKey('code') &&
        !callback.queryParameters.containsKey('error')) {
      return null;
    }
    final stored = readSession();
    clearSession();
    replaceUrl('${callback.origin}/');
    if (stored == null) {
      throw const FormatException('Sign-in session missing');
    }
    final session = jsonDecode(stored) as Map<String, dynamic>;
    final age = now().millisecondsSinceEpoch - (session['created'] as int);
    if (age < 0 ||
        age > const Duration(minutes: 10).inMilliseconds ||
        callback.queryParameters['state'] != session['state'] ||
        session['state'] is! String ||
        (session['state'] as String).isEmpty ||
        '${callback.origin}${callback.path}' != session['redirect'] ||
        (callback.queryParameters['iss'] != null &&
            callback.queryParameters['iss'] != session['issuer']) ||
        callback.queryParameters.containsKey('error') ||
        (callback.queryParameters['code'] ?? '').isEmpty) {
      throw const FormatException('Sign-in verification failed');
    }
    final config = OidcConfig.fromJson({...session, 'enabled': true});
    final response = await client.post(
        Uri.parse('${config.issuer}/protocol/openid-connect/token'),
        body: {
          'client_id': config.clientId,
          'redirect_uri': session['redirect'],
          'grant_type': 'authorization_code',
          'code': callback.queryParameters['code']!,
          'code_verifier': session['verifier'],
        }).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw const FormatException('Sign-in exchange failed');
    }
    final accessToken =
        (jsonDecode(response.body) as Map<String, dynamic>)['access_token'];
    if (accessToken is! String || accessToken.isEmpty) {
      throw const FormatException('Missing access token');
    }
    return accessToken;
  }
}
