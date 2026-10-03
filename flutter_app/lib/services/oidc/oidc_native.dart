import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:http/http.dart' as http;
import 'oidc_flow.dart';

Future<String?> beginOidcLogin(
    OidcConfig config, String locale, http.Client client) async {
  final result = await const FlutterAppAuth()
      .authorizeAndExchangeCode(AuthorizationTokenRequest(
    config.clientId,
    'com.coflnet.con:/oauthredirect',
    discoveryUrl: '${config.issuer}/.well-known/openid-configuration',
    allowInsecureConnections: config.allowInsecureConnections,
    scopes: ['openid', 'profile'],
    additionalParameters: {'ui_locales': locale},
  ));
  return result.accessToken;
}

Future<String?> completeOidcLogin(http.Client client) async => null;
