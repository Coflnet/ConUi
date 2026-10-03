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
The existing cached environment used for these checks is:

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
and removes the PID file and profile after exit. A demonstrated late profile-write
race retries only `ENOTEMPTY` for at most five seconds; persistent or other
cleanup errors fail the run. No browser traces, HARs,
credential screenshots, raw callback URLs, error bodies, or token logs are saved.
Failures print their exception type and the current static UI/API phase without
Playwright's potentially sensitive call log or any typed field value. API progress
prints only method, fixed path, HTTP status and content type. The output contains
only a synthetic backup and boolean/status results; `completed` stays false on
partial runs.

The harness uses Flutter's accessibility semantics for the German UI:

- Text fields receive keyboard input so Flutter controllers update; Keycloak's
  ordinary HTML inputs use `fill`.
- Person-add chips expose `checkbox`; relationship dropdown choices expose
  `menuitem`. Navigation button names include `Tab 1 von 5` through `Tab 5 von 5`.
- Story and Settings buttons merge titles with dates or subtitles. `open_item`
  matches an anchored title followed by whitespace; ordinary controls retain
  exact labels. Participant names include the avatar initial, so assertions
  match the person name at the end of the button name.
- The harness waits for `Aufnahme als Text` after stopping recording, which
  proves finalization and attachment before typing and saving the story.
- Playback, relationship entry and back navigation use forced physical clicks
  for demonstrated overlapping semantics hit targets. Playback still must
  advance the actual media clock, and relationship creation must show the
  saved result. The friend relationship submit button is `Hinzufügen`.
- The encryption-lock Snackbar is checked in semantics text because its exact
  text locator did not expose the visible message reliably.

Backups are ZIP files. The restore picker accepts `.zip`; the archive contains
`manifest.json`, `data.json`, `README.txt`, and `recordings/<id>.wav`. Format version
1 records each recording's byte count and SHA-256 digest. Independent disposable
local checks verified the story/recording/relationship workflow, ZIP recording
integrity, and fresh-profile restore with actual playback. Hosted completion is
established only by a successful full run against the deployed release: require
exit status zero and `result.json` with `completed: true`, then verify temporary
identity/token cleanup through the protected operator flow. A partial result or
local run alone does not establish hosted completion.
