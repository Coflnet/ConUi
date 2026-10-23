"""Read/patch application realms' email-first registration settings through private identity administration."""
import argparse
import copy
import json
import sys


THEMES = {'con': 'con-registration', 'wald': 'wald', 'vereiner': 'vereiner', 'rfind': 'rfind-registration'}


def configure_registration(admin, *, realm='con', apply=False):
    if realm not in THEMES:
        raise ValueError('Only application realms support simplified registration')
    theme = THEMES[realm]
    current = admin.realm(realm)
    profile = admin.realm(realm, path='/users/profile')
    desired = copy.deepcopy(profile)
    attributes = {attribute['name']: attribute for attribute in desired['attributes']}
    if not {'email', 'username', 'firstName', 'lastName'} <= attributes.keys():
        raise RuntimeError('Application user profile is missing standard registration attributes')
    for name in ('firstName', 'lastName'):
        attributes[name].pop('required', None)
    required = attributes['email'].setdefault('required', {})
    required['roles'] = list(dict.fromkeys([*required.get('roles', []), 'user']))
    desired['attributes'] = [attributes['email'],
        *(attribute for attribute in desired['attributes'] if attribute['name'] != 'email')]
    # Preserve registration access and username policy, especially RFInD's
    # administrator-provisioned accounts. This changes form usability only.
    fields = {'loginTheme': theme}
    changes = {key: value for key, value in fields.items() if current.get(key) != value}
    result = {'realm': realm, 'realmFields': sorted(changes),
              'profileChanged': desired != profile, 'applied': apply}
    if not apply:
        return result
    themes = admin.request('GET', '/admin/serverinfo')['themes']['login']
    if not any(item['name'] == theme for item in themes):
        raise RuntimeError('Install the selected registration theme before activating it')
    # The profile endpoint accepts a whole document, so retain every unrelated
    # attribute/validation/permission and stop if it changed since our read.
    if desired != profile:
        if admin.realm(realm, path='/users/profile') != profile:
            raise RuntimeError('Application user profile changed during registration preflight')
        admin.realm(realm, 'PUT', '/users/profile', desired)
    if changes:
        if admin.realm(realm) != current:
            raise RuntimeError('Application realm changed during registration preflight')
        admin.realm(realm, 'PUT', body=changes)
    actual = admin.realm(realm, path='/users/profile')
    if actual != desired or any(admin.realm(realm).get(key) != value for key, value in fields.items()):
        raise RuntimeError('Application registration readback differs')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--identity-url', required=True)
    parser.add_argument('--ca', required=True)
    parser.add_argument('--connect-host', default='127.0.0.1')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--realms', nargs='+', choices=THEMES, default=['con'])
    args = parser.parse_args()
    # Reuse the shared service's verified TLS transport and scoped machine
    # principal; never use a human/root password grant or print credential data.
    from identity.admin import Admin
    payload = json.load(sys.stdin)
    credentials = payload['data']['data']['permanent_admin']
    admin = Admin(args.identity_url, args.ca, credentials, connect_host=args.connect_host)
    try:
        others = {name: admin.realm(name) for name in ('master', *THEMES) if name not in args.realms}
        result = [configure_registration(admin, realm=name, apply=args.apply) for name in dict.fromkeys(args.realms)]
        if any(admin.realm(name) != value for name, value in others.items()):
            raise RuntimeError('An unrelated identity realm changed during registration work')
        print(json.dumps(result))
    finally:
        admin.close()
        credentials.clear()
        payload.clear()


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('Registration configuration failed: ' + (str(error) if type(error) is RuntimeError
                                             else type(error).__name__), file=sys.stderr)
        raise SystemExit(1) from None
