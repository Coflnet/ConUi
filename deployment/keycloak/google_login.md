# Google login preparation

`google_login.py` inspects selected application realms by default. It creates or
enables the `google` provider only with `--apply` and explicit credentials for
each selected realm. It never edits `master`, registration settings, users,
authentication flows, other providers, or an already enabled Google provider.

Create the Google client first in [Google Cloud Console](https://console.cloud.google.com/):

1. Create/select an application project, starting with Con. Use separate projects
   when the apps need different Google consent branding or privacy policies.
2. Open **Google Auth Platform → Branding**. Set the app name, support email,
   homepage and privacy-policy URL; add the owned `coflnet.com` domain.
3. Under **Audience**, choose **External** for public users. Complete the
   console's publishing and brand/domain verification steps before public use.
4. Under **Clients → Create client**, choose **Web application**. Keycloak is
   Google's OAuth client even when the end user uses the Flutter mobile app.
   Add exactly `https://auth.coflnet.com/auth/realms/con/broker/google/endpoint`
   as an authorized redirect URI. Use the corresponding realm callback below
   for Wald or Vereiner clients. Request only `openid profile email`.
5. Download/store the client ID and secret securely. Supply the local credential
   file path or OpenBao location to the operator; never paste the secret into
   chat, Git or command arguments. The operator can then configure the provider
   through the scoped helper below, enable its reviewed egress, and test login.

Google documents these steps in its [OpenID Connect setup](https://developers.google.com/identity/openid-connect/openid-connect)
and [brand verification guide](https://developers.google.com/identity/verification/authentication-policy-compliance).

No live Google configuration has been applied. The installed private
administrator currently lacks `view-identity-providers` and
`manage-identity-providers`; inspection can return HTTP 403 until an authorized,
appropriately scoped principal is supplied. The helper reports that failure
without printing server response bodies or credentials, and does not expand
its own permissions. Google client credentials must also be supplied for each
app; they are not cloned from another realm.

Use the verified `identity.admin` transport and protected short-lived OpenBao
child-session procedure in [README.md](README.md). Keep both administrator and
Google credentials in memory and pass them only through stdin, never command
arguments, shell history, source files, or logs. The input is the existing
OpenBao bootstrap JSON envelope, optionally extended with a `google` map:

```json
{
  "data": {"data": {"permanent_admin": {
    "client_id": "<scoped machine principal>",
    "client_secret": "<administrator secret>"
  }}},
  "google": {
    "con": {"client_id": "<Con Google client ID>", "client_secret": "<Con Google client secret>"},
    "wald": {"client_id": "<Wald Google client ID>", "client_secret": "<Wald Google client secret>"},
    "vereiner": {"client_id": "<Vereiner Google client ID>", "client_secret": "<Vereiner Google client secret>"}
  }
}
```

Supply that stdin to the helper using the existing service forward and CA:

```sh
PYTHONPATH=/path/to/RfindPlatform python3 deployment/keycloak/google_login.py \
  --identity-url https://auth.coflnet.com:18443/auth --ca /path/to/identity-ca.crt \
  --realms con wald vereiner
```

The default output contains only realm names and configuration booleans. It
requires no Google credential map. For the reviewed operation, append `--apply`
and supply all selected realms' credentials in that map. Masked credentials
such as `**********` are rejected as input. A newly created provider uses scopes
`openid profile email`, disables token storage and trusted-email shortcuts,
and selects Keycloak's standard `first broker login` flow. Standard interactive
account linking remains in effect; this helper installs no automatic linking.
An existing disabled provider retains unrelated fields; unsafe custom linking,
token storage, or hidden/login-only policies block enabling. Already enabled
providers remain unchanged, including explicit administrator policy. This is
not a credential rotation tool. Masked secret readback confirms configuration
presence, not equality with the supplied secret or successful Google login.
Repeated application is a no-op once the selected provider is enabled.

Register the corresponding exact redirect URI in each app's Google OAuth web
client:

- `https://auth.coflnet.com/auth/realms/con/broker/google/endpoint`
- `https://auth.coflnet.com/auth/realms/wald/broker/google/endpoint`
- `https://auth.coflnet.com/auth/realms/vereiner/broker/google/endpoint`

RFInD must be selected separately with `--realms rfind` and its own credential
entry. Closed RFInD registration blocks creating/enabling Google by default:
broker first login can admit new users despite `registrationAllowed=false`.
Only after reviewing that access-policy change may `--allow-closed-rfind` be
used. Its callback is
`https://auth.coflnet.com/auth/realms/rfind/broker/google/endpoint`.
The helper never changes `registrationAllowed` itself.

Google token/userinfo exchange also needs the separately reviewed identity
service egress policy; this helper does not modify networking. Fleet's
`keycloak.googleLoginEgress` flag remains `false`. Once credentials and scoped
administration are ready, enabling that reviewed flag permits HTTPS/443 only
to `oauth2.googleapis.com`, `openidconnect.googleapis.com`, and
`www.googleapis.com` (plus the policy's DNS observation). Those endpoints match
the deployed Keycloak 26.7.5 Google provider. Actual hosted Google login remains
unverified until credentials, scoped administration, Google consent/callback
configuration and egress are ready. Current hosted login pages show no Google
button; private identity-provider inspection currently returns HTTP 403.

Run focused tests without contacting any service:

```sh
python3 -m unittest discover -s deployment/keycloak -p test_google_login.py -v
```
