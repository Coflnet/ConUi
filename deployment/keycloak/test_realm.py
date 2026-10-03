import unittest
from realm import realm, NATIVE_CALLBACK


class RealmTests(unittest.TestCase):
    def test_access_token_includes_subject_scope(self):
        self.assertIn('basic', realm('https://con.coflnet.com')['clients'][0]['defaultClientScopes'])

    def test_public_pkce_client_has_exact_callbacks_and_api_audience(self):
        config = realm('https://con.coflnet.com/')
        self.assertEqual('con', config['realm'])
        self.assertNotIn('users', config)
        client = config['clients'][0]
        self.assertEqual(['https://con.coflnet.com/', NATIVE_CALLBACK], client['redirectUris'])
        self.assertEqual(['https://con.coflnet.com'], client['webOrigins'])
        self.assertEqual('S256', client['attributes']['pkce.code.challenge.method'])
        self.assertTrue(client['publicClient'])
        for key in ('implicitFlowEnabled', 'directAccessGrantsEnabled', 'serviceAccountsEnabled'):
            self.assertFalse(client[key])
        self.assertNotIn('secret', client)
        self.assertEqual('con-api', client['protocolMappers'][0]['config']['included.custom.audience'])

    def test_rejects_unsafe_origins(self):
        for origin in ('http://con.coflnet.com', 'https://*.coflnet.com',
                       'https://user:password@con.coflnet.com', 'https://con.coflnet.com/path',
                       'https://con.coflnet.com/?redirect=evil', 'https://con.coflnet.com/#fragment'):
            with self.subTest(origin=origin), self.assertRaises(ValueError):
                realm(origin)

    def test_loopback_can_use_http_for_disposable_identity_tests(self):
        client = realm('http://127.0.0.1:18761')['clients'][0]
        self.assertEqual('http://127.0.0.1:18761/', client['redirectUris'][0])


if __name__ == '__main__':
    unittest.main()
