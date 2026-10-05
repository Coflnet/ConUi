import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:http/http.dart' as http;
import 'auth_transport.dart';
import 'oidc_flow.dart';

Future<String?> beginOidcLogin(
    OidcConfig config, String locale, http.Client client) async {
  const appAuth = FlutterAppAuth();
  const redirect = 'com.coflnet.con:/oauthredirect';
  final authorization = await appAuth.authorize(AuthorizationRequest(
    config.clientId,
    redirect,
    discoveryUrl: '${config.issuer}/.well-known/openid-configuration',
    allowInsecureConnections: config.allowInsecureConnections,
    scopes: ['openid', 'profile'],
    additionalParameters: {'ui_locales': locale},
  )); // Human authorization has no machine-request deadline.
  if ((authorization.authorizationCode ?? '').isEmpty ||
      (authorization.codeVerifier ?? '').isEmpty ||
      (authorization.nonce ?? '').isEmpty) {
    throw const FormatException('Incomplete authorization');
  }
  final remaining = authRemaining();
  final result = await appAuth
      .token(TokenRequest(
        config.clientId,
        redirect,
        discoveryUrl: '${config.issuer}/.well-known/openid-configuration',
        allowInsecureConnections: config.allowInsecureConnections,
        authorizationCode: authorization.authorizationCode,
        codeVerifier: authorization.codeVerifier,
        nonce: authorization.nonce,
        scopes: ['openid', 'profile'],
      ))
      .timeout(remaining, onTimeout: () => throw OidcUnavailable());
  return result.accessToken;
}

Future<String?> completeOidcLogin(http.Client client) async => null;
