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
