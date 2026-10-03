import 'package:web/web.dart' as web;
import 'package:http/http.dart' as http;
import 'oidc_flow.dart';

OidcWebFlow _flow() => OidcWebFlow(
      currentUrl: () => web.window.location.href,
      readSession: () => web.window.sessionStorage.getItem('con.oidc'),
      writeSession: (value) =>
          web.window.sessionStorage.setItem('con.oidc', value),
      clearSession: () => web.window.sessionStorage.removeItem('con.oidc'),
      navigate: (url) => web.window.location.assign(url),
      replaceUrl: (url) => web.window.history.replaceState(null, '', url),
    );
Future<String?> beginOidcLogin(
        OidcConfig config, String locale, http.Client client) =>
    _flow().login(config, locale);
Future<String?> completeOidcLogin(http.Client client) => _flow().finish(client);
