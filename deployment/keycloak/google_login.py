"""Inspect or explicitly enable Google login in selected application realms."""
import argparse
import copy
import json
import sys

REALMS = ('con', 'wald', 'vereiner', 'rfind')
PATH = '/identity-provider/instances'
SCOPE = 'openid profile email'


def masked(value):
    return isinstance(value, str) and bool(value) and set(value) == {'*'}


def validate_credentials(credentials):
    if not isinstance(credentials, dict) or any(
            not isinstance(credentials.get(key), str) or not credentials[key].strip()
            or credentials[key] != credentials[key].strip() or masked(credentials[key])
            for key in ('client_id', 'client_secret')):
        raise ValueError('Explicit, unmasked Google client credentials are required for each selected realm')


def provider(admin, realm):
    rows = [row for row in admin.realm(realm, path=PATH) if row.get('alias') == 'google']
    if len(rows) > 1 or rows and rows[0].get('providerId') != 'google':
        raise RuntimeError('Existing Google alias is not a unique Google provider')
    return rows[0] if rows else None


def secure_linking(current):
    return (not current.get('trustEmail', False)
            and current.get('firstBrokerLoginFlowAlias') in (None, '', 'first broker login'))


def report(realm, settings, current, applied=False):
    current = current or {}
    config = current.get('config', {})
    return {'realm': realm, 'exists': bool(current), 'enabled': bool(current.get('enabled')),
        'registrationAllowed': bool(settings.get('registrationAllowed')),
        'clientIdConfigured': bool(config.get('clientId')),
        'clientSecretConfigured': bool(config.get('clientSecret')),
        'clientSecretMasked': masked(config.get('clientSecret')),
        'secureLinking': secure_linking(current),
        'tokenStorageDisabled': not current.get('storeToken', False),
        'scopeReady': set(config.get('defaultScope', '').split()) == set(SCOPE.split()),
        'applied': applied}


def configure_google(admin, *, realm, credentials=None, apply=False, allow_closed_rfind=False):
    if realm not in REALMS:
        raise ValueError('Only explicitly selected application realms support this helper')
    if apply:
        validate_credentials(credentials)
    settings = admin.realm(realm)
    current = provider(admin, realm)
    if not apply or current and current.get('enabled'):
        # Enabling a provider is not authorization to rotate credentials or
        # overwrite an existing administrator's identity/linking policy.
        return report(realm, settings, current)
    if realm == 'rfind' and not settings.get('registrationAllowed') and not allow_closed_rfind:
        raise RuntimeError('RFInD registration is closed; Google login requires explicit --allow-closed-rfind review')
    if current and (not secure_linking(current) or current.get('storeToken', False)
                    or current.get('linkOnly', False)
                    or current.get('config', {}).get('hideOnLogin') == 'true'):
        raise RuntimeError('Refusing to enable Google with nondefault linking, token storage, or hidden-login policy')
    desired = copy.deepcopy(current) if current else {
        'alias': 'google', 'providerId': 'google', 'trustEmail': False,
        'storeToken': False, 'addReadTokenRoleOnCreate': False,
        'firstBrokerLoginFlowAlias': 'first broker login', 'config': {'defaultScope': SCOPE}}
    desired['enabled'] = True
    desired.setdefault('config', {}).update(clientId=credentials['client_id'], clientSecret=credentials['client_secret'])
    if provider(admin, realm) != current or admin.realm(realm) != settings:
        raise RuntimeError('Google provider or realm changed during preflight')
    admin.realm(realm, 'PUT' if current else 'POST', PATH + ('/google' if current else ''), desired)
    actual = provider(admin, realm)
    if not actual or any(actual.get(key) != value for key, value in desired.items() if key != 'config'):
        raise RuntimeError('Google provider readback differs')
    expected_config = dict(desired['config'])
    expected_config.pop('clientSecret')
    actual_config = actual.get('config', {})
    secret = actual_config.get('clientSecret')
    if (any(actual_config.get(key) != value for key, value in expected_config.items())
            or not secret or not masked(secret) and secret != credentials['client_secret']):
        raise RuntimeError('Google configuration readback differs')
    return report(realm, settings, actual, applied=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--identity-url', required=True)
    parser.add_argument('--ca', required=True)
    parser.add_argument('--connect-host', default='127.0.0.1')
    parser.add_argument('--realms', nargs='+', choices=REALMS, required=True)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--allow-closed-rfind', action='store_true')
    args = parser.parse_args()
    from identity.admin import Admin
    payload = json.load(sys.stdin)
    credentials = payload['data']['data']['permanent_admin']
    google = payload.get('google', {})
    admin = None
    try:
        if args.apply:
            for realm in args.realms:
                validate_credentials(google.get(realm))
        admin = Admin(args.identity_url, args.ca, credentials, connect_host=args.connect_host)
        result = [configure_google(admin, realm=realm, credentials=google.get(realm),
            apply=args.apply, allow_closed_rfind=args.allow_closed_rfind)
            for realm in dict.fromkeys(args.realms)]
        print(json.dumps(result))
    except RuntimeError as error:
        if 'HTTP 403' in str(error):
            raise RuntimeError('Private identity administration forbidden (HTTP 403; view/manage-identity-providers required)') from None
        raise
    finally:
        if admin:
            admin.close()
        credentials.clear()
        for values in google.values():
            if isinstance(values, dict):
                values.clear()
        payload.clear()


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('Google login configuration failed: ' + (str(error) if type(error) in (RuntimeError, ValueError)
              else type(error).__name__), file=sys.stderr)
        raise SystemExit(1) from None
