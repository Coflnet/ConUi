import copy
import io
import json
import sys
import types
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

from google_login import configure_google, main, SCOPE

CREDS = {'client_id': 'synthetic-client.apps.googleusercontent.com', 'client_secret': 'synthetic-google-secret'}


class FakeAdmin:
    def __init__(self, current=None, mask=True):
        self.settings = {'registrationAllowed': True, 'unrelated': {'keep': True}}
        self.current = copy.deepcopy(current)
        self.mask = mask
        self.calls = []
        self.writes = []

    def realm(self, realm, method='GET', path='', body=None):
        assert realm in ('con', 'wald', 'vereiner', 'rfind')
        self.calls.append((realm, method, path))
        if not path:
            return copy.deepcopy(self.settings)
        assert path in ('/identity-provider/instances', '/identity-provider/instances/google')
        if method != 'GET':
            self.writes.append(copy.deepcopy(body))
            self.current = copy.deepcopy(body)
            self.current.setdefault('internalId', 'synthetic-provider-id')
            return None
        result = copy.deepcopy(self.current)
        if result and self.mask and result.get('config', {}).get('clientSecret'):
            result['config']['clientSecret'] = '**********'
        return [result] if result else []


def existing(**overrides):
    return {'alias': 'google', 'providerId': 'google', 'enabled': False,
        'trustEmail': False, 'storeToken': False, 'firstBrokerLoginFlowAlias': 'first broker login',
        'config': {'clientId': 'prior-client', 'clientSecret': 'prior-secret',
                   'defaultScope': SCOPE, 'unrelated': 'keep'},
        'displayName': 'Existing administrator label', **overrides}


class GoogleLoginTests(unittest.TestCase):
    def test_inspect_is_read_only_and_printable_without_credential_strings(self):
        admin = FakeAdmin(existing())
        result = configure_google(admin, realm='con')
        self.assertEqual(admin.writes, [])
        self.assertTrue(result['clientSecretConfigured'])
        self.assertTrue(result['clientSecretMasked'])
        self.assertNotIn('prior-', json.dumps(result))
        self.assertTrue(all(isinstance(value, bool) for key, value in result.items() if key != 'realm'))

    def test_new_provider_secure_defaults_same_realm_and_idempotence_with_masked_secret(self):
        admin = FakeAdmin()
        result = configure_google(admin, realm='wald', credentials=CREDS, apply=True)
        self.assertTrue(result['applied'])
        body = admin.writes[0]
        self.assertEqual(body['providerId'], 'google')
        self.assertEqual(body['firstBrokerLoginFlowAlias'], 'first broker login')
        self.assertFalse(body['trustEmail'])
        self.assertFalse(body['storeToken'])
        self.assertFalse(body['addReadTokenRoleOnCreate'])
        self.assertEqual(body['config'], {'clientId': CREDS['client_id'], 'clientSecret': CREDS['client_secret'], 'defaultScope': SCOPE})
        self.assertEqual({call[0] for call in admin.calls}, {'wald'})
        self.assertFalse(configure_google(admin, realm='wald', credentials=CREDS, apply=True)['applied'])
        self.assertEqual(len(admin.writes), 1)

    def test_enabling_existing_preserves_every_unrelated_field_and_replaces_mask_not_secret_placeholder(self):
        before = existing()
        admin = FakeAdmin(before)
        configure_google(admin, realm='con', credentials=CREDS, apply=True)
        expected = copy.deepcopy(before)
        expected['enabled'] = True
        expected['config'].update(clientId=CREDS['client_id'], clientSecret=CREDS['client_secret'])
        self.assertEqual(admin.writes, [expected])
        self.assertNotEqual(admin.writes[0]['config']['clientSecret'], '**********')

    def test_already_enabled_provider_preserves_explicit_administrator_policy(self):
        before = existing(enabled=True, trustEmail=True, storeToken=True, firstBrokerLoginFlowAlias='custom-flow')
        admin = FakeAdmin(before)
        result = configure_google(admin, realm='con', credentials=CREDS, apply=True)
        self.assertFalse(result['secureLinking'])
        self.assertFalse(result['applied'])
        self.assertEqual(admin.current, before)
        self.assertEqual(admin.writes, [])

    def test_unsafe_disabled_provider_refuses_before_write(self):
        for override in ({'trustEmail': True}, {'storeToken': True}, {'linkOnly': True},
                         {'firstBrokerLoginFlowAlias': 'auto-link'}):
            admin = FakeAdmin(existing(**override))
            with self.assertRaisesRegex(RuntimeError, 'Refusing'):
                configure_google(admin, realm='con', credentials=CREDS, apply=True)
            self.assertEqual(admin.writes, [])

    def test_never_master_and_closed_rfind_requires_explicit_review(self):
        admin = FakeAdmin()
        with self.assertRaises(ValueError):
            configure_google(admin, realm='master', credentials=CREDS, apply=True)
        self.assertEqual(admin.calls, [])
        admin.settings['registrationAllowed'] = False
        configure_google(admin, realm='rfind')
        with self.assertRaisesRegex(RuntimeError, 'registration is closed'):
            configure_google(admin, realm='rfind', credentials=CREDS, apply=True)
        self.assertEqual(admin.writes, [])
        configure_google(admin, realm='rfind', credentials=CREDS, apply=True, allow_closed_rfind=True)
        self.assertFalse(admin.settings['registrationAllowed'])

    def test_apply_requires_exact_unmasked_credentials_even_for_existing_provider(self):
        for credentials in (None, {}, {'client_id': 'other-realm'}, {**CREDS, 'client_secret': '**********'}):
            admin = FakeAdmin(existing(enabled=True))
            with self.assertRaises(ValueError):
                configure_google(admin, realm='con', credentials=credentials, apply=True)
            self.assertEqual(admin.calls, [])

    def test_concurrent_change_stops_write(self):
        admin = FakeAdmin(existing())
        read = admin.realm
        def concurrent(realm, method='GET', path='', body=None):
            if len(admin.calls) == 2:
                admin.current['displayName'] = 'Updated concurrently'
            return read(realm, method, path, body)
        admin.realm = concurrent
        with self.assertRaisesRegex(RuntimeError, 'changed during preflight'):
            configure_google(admin, realm='con', credentials=CREDS, apply=True)
        self.assertEqual(admin.writes, [])

    def test_unmasked_secret_readback_is_checked(self):
        admin = FakeAdmin(mask=False)
        self.assertTrue(configure_google(admin, realm='con', credentials=CREDS, apply=True)['applied'])
        admin = FakeAdmin(mask=False)
        read = admin.realm
        def wrong_secret(realm, method='GET', path='', body=None):
            result = read(realm, method, path, body)
            if method == 'GET' and path and result:
                result[0]['config']['clientSecret'] = 'incorrect-synthetic-secret'
            return result
        admin.realm = wrong_secret
        with self.assertRaisesRegex(RuntimeError, 'readback differs'):
            configure_google(admin, realm='con', credentials=CREDS, apply=True)

    def test_cli_does_not_clone_credentials_across_selected_realms_or_write_partial_config(self):
        calls, _ = self.run_cli({'google': {'con': CREDS}}, ['--apply', '--realms', 'con', 'wald'], ValueError)
        self.assertEqual(calls, [])

    def run_cli(self, extra, args, error):
        payload = {'data': {'data': {'permanent_admin': {'client_id': 'admin', 'client_secret': 'synthetic-admin-secret'}}}, **extra}
        calls = []
        class ForbiddenAdmin:
            def __init__(self, url, ca, credentials, **kwargs):
                calls.append(credentials)
            def realm(self, *args, **kwargs):
                raise RuntimeError('Private identity administration request failed: GET /admin/realms/con/identity-provider/instances HTTP 403')
            def close(self):
                calls.append('closed')
        module = types.ModuleType('identity.admin')
        module.Admin = ForbiddenAdmin
        output = io.StringIO()
        with patch.dict(sys.modules, {'identity': types.ModuleType('identity'), 'identity.admin': module}), \
             patch.object(sys, 'argv', ['google_login.py', '--identity-url', 'https://auth.example.invalid/auth', '--ca', '/synthetic-ca', *args]), \
             patch.object(sys, 'stdin', io.StringIO(json.dumps(payload))), redirect_stdout(output):
            with self.assertRaises(error) as caught:
                main()
        self.assertEqual(output.getvalue(), '')
        self.assertNotIn('synthetic-', str(caught.exception))
        return calls, str(caught.exception)

    def test_403_is_concise_closes_admin_and_clears_credentials(self):
        calls, message = self.run_cli({}, ['--realms', 'con'], RuntimeError)
        self.assertIn('HTTP 403', message)
        self.assertIn('view/manage-identity-providers', message)
        self.assertEqual(calls, [{}, 'closed'])


if __name__ == '__main__':
    unittest.main()
