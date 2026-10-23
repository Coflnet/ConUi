import copy
import unittest

from registration import configure_registration


class FakeAdmin:
    def __init__(self, realm='con'):
        self.name = realm
        self.current = {'realm': 'con', 'loginTheme': 'keycloak.v2',
            'registrationAllowed': True, 'registrationEmailAsUsername': False,
            'loginWithEmailAllowed': True, 'smtpServer': {'host': 'preserve'},
            'attributes': {'unrelated': 'keep'}}
        self.profile = {'attributes': [
            {'name': 'username', 'required': {'roles': ['user']},
             'validations': {'length': {'min': 3}}},
            {'name': 'firstName', 'required': {'roles': ['user']},
             'permissions': {'edit': ['admin', 'user']}},
            {'name': 'email', 'validations': {'email': {}},
             'required': {'roles': ['admin']}},
            {'name': 'lastName', 'required': {'scopes': ['profile']}},
            {'name': 'con.e2e', 'permissions': {'edit': ['admin']}}],
            'groups': [{'name': 'unchanged'}]}
        self.writes = []
        self.theme_installed = True

    def realm(self, name, method='GET', path='', body=None):
        assert name == self.name
        assert path in ('', '/users/profile')
        if method == 'PUT':
            self.writes.append((path, copy.deepcopy(body)))
            if path:
                self.profile = copy.deepcopy(body)
            else:
                self.current.update(body)
        return copy.deepcopy(self.profile if path else self.current)

    def request(self, method, path):
        assert (method, path) == ('GET', '/admin/serverinfo')
        return {'themes': {'login': [{'name': name} for name in ('con-registration', 'wald', 'vereiner', 'rfind-registration')] if self.theme_installed else []}}


class RegistrationTests(unittest.TestCase):
    def test_inspection_is_read_only(self):
        admin = FakeAdmin()
        self.assertEqual(configure_registration(admin), {'realm': 'con',
            'realmFields': ['loginTheme'], 'profileChanged': True, 'applied': False})
        self.assertEqual(admin.writes, [])

    def test_minimal_profile_preserves_every_unrelated_setting_and_is_repeatable(self):
        admin = FakeAdmin()
        before = copy.deepcopy(admin.profile)
        realm_before = copy.deepcopy(admin.current)
        configure_registration(admin, apply=True)
        self.assertEqual(admin.current, {**realm_before, 'loginTheme': 'con-registration'})
        self.assertEqual(admin.profile['attributes'][0]['name'], 'email')
        after = {row['name']: row for row in admin.profile['attributes']}
        for row in before['attributes']:
            expected = copy.deepcopy(row)
            if row['name'] in ('firstName', 'lastName'):
                expected.pop('required')
            if row['name'] == 'email':
                expected['required']['roles'].append('user')
            self.assertEqual(after[row['name']], expected)
        self.assertEqual(admin.profile['groups'], before['groups'])
        self.assertEqual(admin.writes[-1], ('', {'loginTheme': 'con-registration'}))
        configure_registration(admin, apply=True)
        self.assertEqual(len(admin.writes), 2)

    def test_missing_theme_or_nonstandard_profile_blocks_before_any_write(self):
        for missing_theme in (True, False):
            admin = FakeAdmin()
            if missing_theme:
                admin.theme_installed = False
            else:
                admin.profile['attributes'].pop(1)
            with self.assertRaises(RuntimeError):
                configure_registration(admin, apply=True)
            self.assertEqual(admin.writes, [])

    def test_other_realms_preserve_registration_access_and_username_policy(self):
        for realm, theme in [('wald', 'wald'), ('vereiner', 'vereiner'),
                             ('rfind', 'rfind-registration')]:
            admin = FakeAdmin(realm)
            admin.current.update(registrationAllowed=False, registrationEmailAsUsername=True)
            configure_registration(admin, realm=realm, apply=True)
            self.assertFalse(admin.current['registrationAllowed'])
            self.assertTrue(admin.current['registrationEmailAsUsername'])
            self.assertEqual(admin.current['loginTheme'], theme)

    def test_master_is_never_modified(self):
        admin = FakeAdmin('master')
        with self.assertRaises(ValueError):
            configure_registration(admin, realm='master', apply=True)
        self.assertEqual(admin.writes, [])

    def test_concurrent_profile_change_is_not_overwritten(self):
        admin = FakeAdmin()
        read = admin.realm
        calls = 0
        def concurrent(name, method='GET', path='', body=None):
            nonlocal calls
            if method == 'GET' and path == '/users/profile':
                calls += 1
                if calls == 2:
                    admin.profile['groups'].append({'name': 'new'})
            return read(name, method, path, body)
        admin.realm = concurrent
        with self.assertRaisesRegex(RuntimeError, 'changed during'):
            configure_registration(admin, apply=True)
        self.assertEqual(admin.writes, [])


if __name__ == '__main__':
    unittest.main()
