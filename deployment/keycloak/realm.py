"""Render Con's new Keycloak realm; never contact or modify an identity server."""
import argparse
import json
from urllib.parse import urlsplit


NATIVE_CALLBACK = 'com.coflnet.con:/oauthredirect'


def realm(app_origin):
    url = urlsplit(app_origin)
    if (url.scheme not in ('https', 'http') or not url.hostname or url.username or url.password
            or url.path not in ('', '/') or url.query or url.fragment
            or (url.scheme == 'http' and url.hostname not in ('localhost', '127.0.0.1', '::1'))
            or '*' in app_origin):
        raise ValueError('Use an HTTPS origin, or loopback HTTP for local testing')
    origin = app_origin.rstrip('/')
    return {
        'realm': 'con', 'enabled': True, 'displayName': 'Con',
        'registrationAllowed': True, 'resetPasswordAllowed': True,
        'loginWithEmailAllowed': True, 'duplicateEmailsAllowed': False,
        'bruteForceProtected': True,
        'internationalizationEnabled': True, 'supportedLocales': ['de', 'en'],
        'defaultLocale': 'de',
        'clients': [{
            'clientId': 'con-app', 'name': 'Con', 'enabled': True,
            'protocol': 'openid-connect', 'publicClient': True,
            'standardFlowEnabled': True, 'implicitFlowEnabled': False,
            'directAccessGrantsEnabled': False, 'serviceAccountsEnabled': False,
            'redirectUris': [origin + '/', NATIVE_CALLBACK], 'webOrigins': [origin],
            'attributes': {
                'pkce.code.challenge.method': 'S256',
                'post.logout.redirect.uris': origin + '/##' + NATIVE_CALLBACK,
            },
            'defaultClientScopes': ['basic', 'profile', 'email'],
            'protocolMappers': [{
                'name': 'con-api-audience', 'protocol': 'openid-connect',
                'protocolMapper': 'oidc-audience-mapper',
                'config': {'included.custom.audience': 'con-api',
                           'id.token.claim': 'false', 'access.token.claim': 'true'},
            }],
        }],
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app-origin', default='https://con.coflnet.com')
    args = parser.parse_args()
    try:
        print(json.dumps(realm(args.app_origin), ensure_ascii=False, indent=2))
    except ValueError as error:
        parser.error(str(error))
