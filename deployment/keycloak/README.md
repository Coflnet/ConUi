# Con sign-in on the shared Keycloak service

## Email-first registration

The current shared issuer is `https://auth.coflnet.com/auth/realms/con`.
Con's `themes/con-registration` login theme keeps the standard Keycloak password form and
validation. Email is first; profile fields sit in an editable disclosure.
`alice12.smith34@example.com` suggests `Alice`, `Smith`, and `alice.smith`.
Manual edits, submitted values and username-collision errors are preserved.
First/last names are optional; email and a unique username remain required.
Without JavaScript, the normal server-rendered fields remain usable.

Run `python3 -m unittest discover -s deployment/keycloak -v` and the two
Playwright checks (`test_registration.cjs`, `test_registration_live.cjs` with
`KEYCLOAK_TEST_BASE` pointing to a disposable loopback instance). Browser checks
must use synthetic accounts, never real account credentials.

Package a reviewed theme with

```sh
python3 deployment/keycloak/package_theme.py /path/to/fleet-worktree \
  --theme con-registration --theme wald --theme vereiner --theme rfind-registration
```

Fleet's identity chart mounts the shared script in Con, Wald and Vereiner,
and an RFInD child theme inheriting its existing branding; its
checksum triggers the normal rolling update. The script filename is hashed to
invalidate browser caches. Keep the source and packaged script in sync.

After all identity replicas have the theme, run `registration.py` inside the
protected OpenBao session, with read access only to
`kv/data/services/identity/bootstrap` plus the session self-management paths.
Use the predecessor `eu-cluster` init authority only to mint that narrow,
short-lived, nonrenewable child. The active OpenBao cluster is
`admin@talos-secrets-hcloud`; use the existing Ansible kubeconfig/local proxy.
The helper must revoke the child, verify HTTP 403, and remove its token artifact
immediately after the operation. The shared identity Python package supplies
the verified TLS transport; the existing `permanent_admin` machine client is
consumed only in memory. Example inside that child session, after forwarding
the identity service's 8443 to loopback 18443 and exporting its public CA:

```sh
bao kv get -mount=kv -format=json services/identity/bootstrap | \
  PYTHONPATH=/path/to/RfindPlatform python3 deployment/keycloak/registration.py \
    --identity-url https://auth.coflnet.com:18443/auth --ca /path/to/identity-ca.crt
```

The default is read-only inspection; append `--apply` for the reviewed change.
Use `--realms con wald vereiner rfind` to inspect/apply all application realms.
The script reads each selected realm, changes only the login theme, email
ordering/requirement and optional names, and verifies readback. Keycloak's
profile endpoint requires a full document: unrelated attributes, validation,
permissions and groups are retained, and a concurrent change stops the write.
Registration access, username policy and all unselected realms stay unchanged.
RFInD currently disables self-registration; the helper preserves that setting.
The master administration realm is never a target. This updates registration policy,
not existing users, client credentials, passwords, sessions or signing keys.

For Google sign-in, see [the scoped provider setup](google_login.md). OAuth
credentials and identity-provider permissions are prerequisites; the helper
never changes the master realm or automatically links accounts by email.

## Original provisioning reference

Con reuses the existing RFInD Keycloak server. Its separate `con` realm and
`con-app` public client follow the existing RFInD/Wald integration pattern.
The separate realm and client are deployed and real hosted PKCE sign-in passes.
Existing RFInD and Wald realms, users, themes, storage and signing keys remain
unchanged. Separate realms do not share user accounts or imply cross-project SSO.

The public configuration is:

```text
Oidc__Issuer=https://app.rfind.de/auth/realms/con
Oidc__ClientId=con-app
Oidc__Audience=con-api
```

Generate a new realm's configuration without contacting any server:

```sh
python3 deployment/keycloak/realm.py > /tmp/con-realm.json
python3 -m unittest discover -s deployment/keycloak -v
```

The allowlist contains exactly `https://con.coflnet.com/` and
`com.coflnet.con:/oauthredirect`. Login uses authorization code flow with S256
PKCE; implicit flow, password grants and service accounts are disabled. There
is no client secret to put in Flutter. The default `basic` client scope supplies the access token's subject claim
(Keycloak 25+). A mapper adds the `con-api` access-token
audience. The backend validates the RS256 signature through cached discovery
and JWKS, the exact issuer/audience, expiry, and `azp=con-app`. Identity is mapped
by issuer and subject, never by matching an email address. It then issues the
existing Con API token and returns the account's existing encryption salt.

The Flutter client reads only public configuration from `/api/auth/config`.
Web callback state is scoped to the tab, expires after ten minutes, binds the
issuer/client/redirect, and is consumed once. The app fetches `/api/auth/me`
before adopting a login. Local stories remain on the device. The account login
password is never used as the story encryption password; sync stays locked
until the user explicitly supplies the separate encryption password.

Fleet's `con-chart` has the prepared OpenBao contract for the namespace-scoped
`kv/con/con-backend` leaf and `jwt-talos-eu` workload role. This path is the new
Con deployment contract, not copied RFInD secret material. The init container
writes `/secrets/appsettings.json` on a memory volume, revokes its temporary
token, and the backend reads the required file through `CON_CONFIG_FILE` before
validating JWT/storage settings. Missing or malformed configured files fail
startup. Public OIDC settings are ordinary deployment configuration.

Persistent Con account storage, the scoped OpenBao leaf/role and chart OIDC gate
are provisioned. S3 remains disabled pending Con-only credentials. Do not import
this JSON over an existing realm: first read the
current objects and patch only required Con fields. Con is registered as a prepared
consumer in RFInD's `docs/SHARED-IDENTITY.md`.
Password reset requires SMTP configuration for the Con realm. No live realm,
OpenBao role, secret or cluster resource is created by this generator.

For a disposable local identity test, use `--app-origin http://127.0.0.1:18761`
and a local Keycloak instance. HTTP issuer support requires both backend
`Development` plus `Oidc__AllowInsecureLocalhost=true` and the Flutter build flag
`--dart-define=ALLOW_INSECURE_LOCAL_OIDC=true`; only loopback hosts are accepted.
Production builds omit that flag and require HTTPS. Never add real users or
credentials to generated test fixtures or logs.


Approved live provisioning uses `provision.py`; it consumes the shared identity
bootstrap JSON through stdin and prints only operation status. Run it inside the
protected `fleet/openbao/scripts/openbao-local-session.sh` child session with
an exact task ACL allowing `kv/data/rfind/demo/bootstrap` read,
`auth/token/lookup-self` read, `auth/token/revoke-self` update, and
`sys/capabilities-self` update. Select the protected predecessor init file
explicitly, use `-P` plus `-A` for this narrow policy and `-t 900` or less.
The predecessor authority must only mint the child. Exit the session immediately
after work and require the helper's verified HTTP 403 revocation and artifact
removal. Never print the bootstrap JSON or put credentials in command arguments.

Forward the shared Keycloak service to loopback port 18081, then inside that
child session:

```sh
bao kv get -mount=kv -format=json rfind/demo/bootstrap | python3 deployment/keycloak/provision.py provision
bao kv get -mount=kv -format=json rfind/demo/bootstrap | python3 deployment/keycloak/provision.py create-users --fixture /tmp/con-e2e-users.json
# Run the browser E2E using this protected fixture without logging credentials.
bao kv get -mount=kv -format=json rfind/demo/bootstrap | python3 deployment/keycloak/provision.py cleanup-users --fixture /tmp/con-e2e-users.json
exit
```

Provisioning creates an absent Con realm only. Existing realms are verified and
mismatches stop the operation for review; no realm/user state is overwritten.
Password reset stays disabled without configured Con SMTP. The helper checks
RFInD/Wald realm representations remain unchanged and logs out its Keycloak
admin session in every authenticated operation. Synthetic users carry a unique
ownership marker. The credential artifact is created exclusively with mode 0600;
cleanup checks ownership, deletes only the recorded IDs, verifies HTTP 404, then
removes the artifact. Keep that protected artifact for retry if cleanup fails.
Public `/auth/realms/con` routing and network policy are deployed;
master/admin remain private. Synthetic identity deletion does not remove any
Con API account or sync fixture data created by the browser test.

The helper registers the exact admin-only managed `con.e2e` attribute in Con's
user profile before creating fixtures, preserving all unrelated profile fields.
Keycloak drops undeclared attributes by default; each created user's marker is
read-back verified after its recovery artifact is saved. Incompatible existing
marker configuration stops creation. Strict cleanup still refuses an absent or
changed marker and retains the protected artifact for audited recovery. The final
hosted run and a fresh create/cleanup cycle verified user deletion and token
revocation; see `deployment/con-provisioning.json`.
