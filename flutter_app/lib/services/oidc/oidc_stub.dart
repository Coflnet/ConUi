import 'package:http/http.dart' as http;
import 'oidc_flow.dart';

Future<String?> beginOidcLogin(
        OidcConfig config, String locale, http.Client client) async =>
    throw UnsupportedError('Sign-in unavailable on this platform');
Future<String?> completeOidcLogin(http.Client client) async => null;
