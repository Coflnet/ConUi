# Con sign-in on the shared Keycloak service

Con reuses the existing RFInD Keycloak server. Its separate `con` realm and
`con-app` public client follow the existing RFInD/Wald integration pattern.
These are prepared configuration, not a claim that the realm is deployed.
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

Before an approved rollout, provision persistent Con account/sync storage and
the scoped OpenBao leaf/role, then create the new realm and enable the chart's
OIDC setting. Do not import this JSON over an existing realm: first read the
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
Public `/auth/realms/con` routing and network policy still require Fleet changes;
master/admin remain private. Synthetic identity deletion does not remove any
Con API account or sync fixture data created by the browser test.
