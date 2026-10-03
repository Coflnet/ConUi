# Hosted Con browser verification

`hosted.py` exercises the production Flutter UI with two synthetic identities:
public PKCE sign-in at desktop/phone sizes, separate account/salt and scoped API
device lists, expected S3-unconfigured HTTP 503, locked encryption sync, a local
story and participant, fake microphone recording and actual media-clock playback,
a story-linked friend relationship, backup download, reload, and backup restore
with playback in a fresh isolated browser context. It never claims cloud sync or
cross-user sharing works. Native interactive login remains outside this harness.

Have the primary operator create the temporary identities with
`deployment/keycloak/provision.py create-users` in its narrow OpenBao child session.
The harness reads only that mode-0600 fixture artifact. It creates no Keycloak
users. Always run `cleanup-users` through the protected session afterward, including
when browser checks fail. Deleting identities does not remove synthetic API account
and device rows; this harness deliberately leaves those marked E2E rows rather
than deleting arbitrary application data.

Use an installed Playwright Python environment with the system Chromium binary.
The existing cached environment used for the prepare check is:

```sh
/home/ekwav/.cache/uv/archive-v0/eq7TXxf37ojESxDq/bin/python deployment/e2e/hosted.py \
  --fixture /tmp/con-e2e-users.json --output /tmp/con-hosted-e2e
```

If direct workstation routing is unavailable, the primary operator can pass an
already established TLS gateway tunnel via, for example,
`--browser-arg='--host-resolver-rules=MAP con.coflnet.com 127.0.0.1:18443'`.
HTTPS verification remains enabled. App fetches run in the actual browser so they
honor its routing; no application authentication is replaced by password grants.

Chromium runs with a unique temporary profile, extensions disabled and a generated
16-kHz mono PCM WAV fake microphone. The harness records only its own PID,
verifies `/proc/<pid>/cmdline` contains its exact profile before termination,
and removes the PID file and profile after exit. No browser traces, HARs,
credential screenshots, raw callback URLs, error bodies, or token logs are saved.
Failures print their exception type and the current static UI/API phase without
Playwright's potentially sensitive call log or any typed field value. The output contains only a synthetic backup and boolean/status results.

Local disposable static-build checks reproduced Flutter's person-add chip as a
checkbox and input updates requiring keyboard events; the harness accounts for
both. The helper must still be run against the deployed release to validate the
complete Flutter semantics workflow. Syntax/help and isolated Chromium checks are preparation only; they
are not evidence that the deployed application passed. First live execution may
expose an accessibility selector mismatch, which should be corrected in this
repeatable script before reporting the workflow verified.
