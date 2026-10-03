"""Provision only Con identity; consume OpenBao bootstrap JSON on stdin."""
import argparse
import json
import os
from pathlib import Path
import secrets
import stat
import sys
import uuid
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, build_opener, ProxyHandler, HTTPRedirectHandler

from realm import realm

MARKER = 'con.e2e'


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, newurl):
        return None


class Http:
    def __init__(self, base):
        self.base = base.rstrip('/')
        self.token = None
        self.opener = build_opener(ProxyHandler({}), NoRedirect())

    def call(self, method, path, *, body=None, form=None, expected=(200, 201, 204)):
        headers = {}
        if self.token:
            headers['Authorization'] = 'Bearer ' + self.token
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers['Content-Type'] = 'application/json'
        if form is not None:
            data = urlencode(form).encode()
            headers['Content-Type'] = 'application/x-www-form-urlencoded'
        try:
            with self.opener.open(Request(self.base + path, data=data, headers=headers, method=method), timeout=25) as response:
                status, raw, location = response.status, response.read(), response.headers.get('Location')
        except HTTPError as error:
            status, raw, location = error.code, b'', None
            error.close()
        except (URLError, TimeoutError):
            raise RuntimeError('Keycloak endpoint unavailable') from None
        if status not in expected:
            raise RuntimeError(f'Keycloak {method} {path}: HTTP {status}')
        return status, json.loads(raw) if raw else None, location


def verify(http):
    current = http.call('GET', '/admin/realms/con')[1]
    desired = realm('https://con.coflnet.com')
    desired['resetPasswordAllowed'] = bool(current.get('smtpServer', {}).get('host'))
    for key, value in desired.items():
        matches = (set(current.get(key, [])) == set(value) if key == 'supportedLocales'
                   else current.get(key) == value)
        if key != 'clients' and not matches:
            raise RuntimeError('Existing Con realm contract differs: ' + key)
    rows = http.call('GET', '/admin/realms/con/clients?clientId=con-app')[1]
    if len(rows) != 1:
        raise RuntimeError('Con requires exactly one con-app client')
    client = http.call('GET', '/admin/realms/con/clients/' + rows[0]['id'])[1]
    for key, value in desired['clients'][0].items():
        if key in ('attributes', 'protocolMappers', 'defaultClientScopes'):
            continue
        matches = (set(client.get(key, [])) == set(value) if key in ('redirectUris', 'webOrigins')
                   else client.get(key) == value)
        if not matches:
            raise RuntimeError('Existing Con client contract differs: ' + key)
    for key, value in desired['clients'][0]['attributes'].items():
        if client.get('attributes', {}).get(key) != value:
            raise RuntimeError('Existing Con client contract differs: ' + key)
    if not set(desired['clients'][0]['defaultClientScopes']).issubset(client.get('defaultClientScopes', [])):
        raise RuntimeError('Con client lacks required default scopes')
    mapper = desired['clients'][0]['protocolMappers'][0]
    matches = [m for m in client.get('protocolMappers', []) if m.get('name') == mapper['name']]
    if len(matches) != 1 or any(matches[0].get(k) != mapper[k] for k in ('protocol', 'protocolMapper')) or any(
            matches[0].get('config', {}).get(k) != v for k, v in mapper['config'].items()):
        raise RuntimeError('Con API audience mapper differs')


def provision(http):
    status, _, _ = http.call('GET', '/admin/realms/con', expected=(200, 404))
    if status == 404:
        desired = realm('https://con.coflnet.com')
        desired['resetPasswordAllowed'] = False
        desired['attributes'] = {'con.managed-by': 'ConUi'}
        http.call('POST', '/admin/realms', body=desired)
    verify(http)


def read_fixture(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077:
            raise RuntimeError('Fixture must be a protected regular file')
        fixture = json.load(handle)
    if fixture.get('realm') != 'con' or not fixture.get('marker') or not 1 <= len(fixture.get('users', [])) <= 2:
        raise RuntimeError('Invalid Con fixture artifact')
    for user in fixture['users']:
        uuid.UUID(user['id'])
        if not user['username'].startswith('con-e2e-'):
            raise RuntimeError('Invalid Con fixture user')
    return fixture


def remove_users(http, fixture):
    for user in fixture['users']:
        path = '/admin/realms/con/users/' + user['id']
        status, current, _ = http.call('GET', path, expected=(200, 404))
        if status == 200:
            if current.get('username') != user['username'] or current.get('attributes', {}).get(MARKER) != [fixture['marker']]:
                raise RuntimeError('Refusing to remove an unowned Con user')
            http.call('DELETE', path)
        if http.call('GET', path, expected=(200, 404))[0] != 404:
            raise RuntimeError('Con test user cleanup failed')


def create_users(http, path):
    # Reserve the artifact before creating users; never overwrite prior credentials.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    fixture = {'realm': 'con', 'marker': secrets.token_hex(16), 'users': []}
    try:
        with os.fdopen(fd, 'w') as handle:
            for _ in range(2):
                username = 'con-e2e-' + secrets.token_hex(12)
                password = secrets.token_urlsafe(32)
                _, _, location = http.call('POST', '/admin/realms/con/users', body={
                    'username': username, 'enabled': True, 'emailVerified': True,
                    'email': username + '@example.invalid', 'firstName': 'Con', 'lastName': 'E2E',
                    'attributes': {MARKER: [fixture['marker']]},
                    'credentials': [{'type': 'password', 'value': password, 'temporary': False}]})
                if not location:
                    raise RuntimeError('Keycloak omitted created user location')
                fixture['users'].append({'id': location.rsplit('/', 1)[1], 'username': username, 'password': password})
                # Persist each successful creation so interrupted runs remain recoverable.
                handle.seek(0)
                json.dump(fixture, handle)
                handle.truncate()
                handle.flush()
                os.fsync(handle.fileno())
    except BaseException:
        if fixture['users']:
            remove_users(http, fixture)
        Path(path).unlink()
        raise


def run(http, bootstrap, mode, fixture_path=None):
    admin = json.loads(bootstrap['data']['data']['files']['demo-bootstrap.json'])['keycloakAdmin']
    tokens = http.call('POST', '/realms/master/protocol/openid-connect/token', form={
        'client_id': 'admin-cli', 'grant_type': 'password', **admin})[1]
    http.token = tokens['access_token']
    try:
        before = {name: http.call('GET', '/admin/realms/' + name)[1] for name in ('rfind', 'wald')}
        if mode == 'provision':
            provision(http)
        elif mode == 'create-users':
            verify(http)
            create_users(http, fixture_path)
        else:
            remove_users(http, read_fixture(fixture_path))
            Path(fixture_path).unlink()
        for name, current in before.items():
            if http.call('GET', '/admin/realms/' + name)[1] != current:
                raise RuntimeError('Shared realm changed during Con operation: ' + name)
    finally:
        http.token = None
        http.call('POST', '/realms/master/protocol/openid-connect/logout', form={
            'client_id': 'admin-cli', 'refresh_token': tokens['refresh_token']})
        tokens.clear()
        admin.clear()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('provision', 'create-users', 'cleanup-users'))
    parser.add_argument('--identity-url', default='http://127.0.0.1:18081/auth')
    parser.add_argument('--fixture')
    args = parser.parse_args()
    url = urlsplit(args.identity_url)
    if url.scheme != 'http' or url.hostname not in ('127.0.0.1', 'localhost', '::1') or url.path != '/auth' or url.username or url.password or url.query or url.fragment:
        parser.error('Use a loopback-only /auth port-forward')
    if args.mode != 'provision' and not args.fixture:
        parser.error('--fixture is required for synthetic users')
    try:
        run(Http(args.identity_url), json.load(sys.stdin), args.mode, args.fixture)
        print('Con identity operation completed: ' + args.mode)
    except Exception as error:
        print('Con identity operation failed: ' + (str(error) if type(error) is RuntimeError else type(error).__name__), file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == '__main__':
    main()
