import copy
import json
from pathlib import Path
import tempfile
import unittest

import provision as p
from realm import realm

BOOTSTRAP = {'data': {'data': {'files': {'demo-bootstrap.json': json.dumps({
    'keycloakAdmin': {'username': 'operator', 'password': 'private-password'}})}}}}


class FakeHttp:
    def __init__(self, exists=True):
        self.token = None
        self.calls = []
        self.current = realm('https://con.coflnet.com') if exists else None
        if self.current:
            self.current['resetPasswordAllowed'] = False
        self.client = realm('https://con.coflnet.com')['clients'][0]
        self.users = {}
        self.fail = None

    def call(self, method, path, **kwargs):
        self.calls.append((method, path, kwargs))
        if self.fail == (method, path):
            raise RuntimeError('Fixture failure')
        if path.endswith('/token'):
            return 200, {'access_token': 'private-token', 'refresh_token': 'private-refresh'}, None
        if path.endswith('/logout'):
            assert self.token is None
            return 204, None, None
        if path in ('/admin/realms/rfind', '/admin/realms/wald'):
            return 200, {'realm': path.rsplit('/', 1)[1], 'unchanged': True}, None
        if method == 'POST' and path == '/admin/realms':
            self.current = copy.deepcopy(kwargs['body'])
            return 201, None, None
        if path == '/admin/realms/con':
            return (200, copy.deepcopy(self.current), None) if self.current else (404, None, None)
        if path == '/admin/realms/con/clients?clientId=con-app':
            return 200, [{'id': 'client-id'}], None
        if path == '/admin/realms/con/clients/client-id':
            return 200, copy.deepcopy(self.client), None
        if path == '/admin/realms/con/users':
            uid = f'00000000-0000-0000-0000-{len(self.users) + 1:012d}'
            self.users[uid] = copy.deepcopy(kwargs['body'])
            return 201, None, 'http://localhost/auth/admin/realms/con/users/' + uid
        if '/users/' in path:
            uid = path.rsplit('/', 1)[1]
            if method == 'DELETE':
                del self.users[uid]
                return 204, None, None
            return (200, copy.deepcopy(self.users[uid]), None) if uid in self.users else (404, None, None)
        raise AssertionError((method, path))


class ProvisionTests(unittest.TestCase):
    def test_creates_absent_con_only_and_disables_reset(self):
        http = FakeHttp(False)
        p.run(http, copy.deepcopy(BOOTSTRAP), 'provision')
        writes = [(m, path) for m, path, _ in http.calls if m in ('POST', 'PUT', 'DELETE')]
        self.assertEqual(writes, [('POST', '/realms/master/protocol/openid-connect/token'),
            ('POST', '/admin/realms'), ('POST', '/realms/master/protocol/openid-connect/logout')])
        self.assertFalse(http.current['resetPasswordAllowed'])
        self.assertEqual(http.current['realm'], 'con')
        self.assertIsNone(http.token)

    def test_existing_realm_and_user_state_are_retained(self):
        http = FakeHttp()
        http.current['smtpServer'] = {'host': 'smtp.example'}
        http.current['resetPasswordAllowed'] = True
        http.current['attributes'] = {'existing': 'preserve'}
        before = copy.deepcopy(http.current)
        p.run(http, copy.deepcopy(BOOTSTRAP), 'provision')
        self.assertEqual(http.current, before)
        self.assertFalse(any(m != 'GET' and path.startswith('/admin/') for m, path, _ in http.calls))

    def test_server_reordered_lists_keep_exact_allowlists(self):
        http = FakeHttp()
        http.current['supportedLocales'].reverse()
        http.client['redirectUris'].reverse()
        p.run(http, copy.deepcopy(BOOTSTRAP), 'provision')
        http.client['redirectUris'].append('https://unexpected.example/')
        with self.assertRaisesRegex(RuntimeError, 'redirectUris'):
            p.run(http, copy.deepcopy(BOOTSTRAP), 'provision')

    def test_contract_mismatches_refuse_and_logout(self):
        for mutate in (lambda h: h.current.update(resetPasswordAllowed=True),
                       lambda h: h.client['defaultClientScopes'].remove('basic'),
                       lambda h: h.client['protocolMappers'][0]['config'].update({'included.custom.audience': 'wrong'}),
                       lambda h: h.client['attributes'].update({'pkce.code.challenge.method': 'plain'})):
            with self.subTest(mutate=mutate):
                http = FakeHttp()
                mutate(http)
                with self.assertRaises(RuntimeError):
                    p.run(http, copy.deepcopy(BOOTSTRAP), 'provision')
                self.assertEqual(http.calls[-1][1], '/realms/master/protocol/openid-connect/logout')
                self.assertFalse(any(m != 'GET' and path.startswith('/admin/') for m, path, _ in http.calls))

    def test_fixture_is_private_and_cleanup_verifies_absence(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'users.json'
            http = FakeHttp()
            p.run(http, copy.deepcopy(BOOTSTRAP), 'create-users', path)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(len(p.read_fixture(path)['users']), 2)
            p.run(http, copy.deepcopy(BOOTSTRAP), 'cleanup-users', path)
            self.assertFalse(path.exists())
            self.assertEqual(http.users, {})

    def test_cleanup_refuses_changed_ownership_and_preserves_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'users.json'
            http = FakeHttp()
            p.create_users(http, path)
            next(iter(http.users.values()))['attributes'] = {}
            with self.assertRaises(RuntimeError):
                p.run(http, copy.deepcopy(BOOTSTRAP), 'cleanup-users', path)
            self.assertTrue(path.exists())
            self.assertEqual(len(http.users), 2)
            self.assertEqual(http.calls[-1][1], '/realms/master/protocol/openid-connect/logout')

    def test_failed_second_create_removes_first_user(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'users.json'
            http = FakeHttp()
            original = http.call
            def call(method, endpoint, **kwargs):
                if method == 'POST' and endpoint.endswith('/users') and http.users:
                    raise RuntimeError('Second create failed')
                return original(method, endpoint, **kwargs)
            http.call = call
            with self.assertRaises(RuntimeError):
                p.create_users(http, path)
            self.assertEqual(http.users, {})
            self.assertFalse(path.exists())

    def test_interrupted_partial_fixture_can_be_cleaned(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'users.json'
            http = FakeHttp()
            p.create_users(http, path)
            fixture = p.read_fixture(path)
            del http.users[fixture['users'].pop()['id']]
            path.write_text(json.dumps(fixture))
            p.run(http, copy.deepcopy(BOOTSTRAP), 'cleanup-users', path)
            self.assertFalse(path.exists())
            self.assertEqual(http.users, {})


if __name__ == '__main__':
    unittest.main()
