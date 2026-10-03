# Hosted Con browser verification

`hosted.py` exercises the production Flutter UI with two synthetic identities:
public PKCE sign-in at desktop/phone sizes, separate account/salt and scoped API
device lists, expected S3-unconfigured HTTP 503, locked encryption sync, a local
story and participant, fake microphone recording and actual media-clock playback,
a story-linked friend relationship, backup download, reload, and backup restore
with playback and original photo viewing in a fresh isolated browser context.
It checks year counts and year navigation, uploads a synthetic PNG through the
picker, and verifies original photo bytes/SHA-256 in the ZIP. German phone/desktop
screenshots cover the new controls. It never claims cloud sync or
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

- Text fields wait for focus and two animation frames before `fill`, allowing
  Flutter's editing listeners to activate. An inactive semantic input can keep an
  older value even when the canvas displays the updated controller text; focus
  the transcript before asserting its value.
- Person-add chips expose `checkbox`; relationship dropdown choices expose
  `menuitem`. Navigation exposes `tab` or a button with a `Tab N von 5` suffix.
  Select roles dynamically across route transitions, without matching tooltips.
- Story and Settings buttons merge titles with dates or subtitles. `open_item`
  matches an anchored title followed by whitespace; ordinary controls retain
  exact labels. Participant names include the avatar initial, so assertions
  match the person name at the end of the button name.
- The harness waits for the Save action to become enabled after stopping, which
  proves recording finalization. Every authenticated transcription request must
  succeed before typing and saving the story.
- Playback, relationship entry and back navigation use forced physical clicks
  for demonstrated overlapping semantics hit targets. Playback still must
  advance the actual media clock, and relationship creation must show the
  saved result. Original photo viewing also uses the demonstrated overlapping
  hit target. Playback assertions inspect active players; disposed historical
  players can report an error after their blob URL is released. The friend
  relationship submit button is `Hinzufügen`.
- Successful restore returns directly to the map; there is no extra Back
  action. Backup creation returns to Settings, which the harness waits for.
- The encryption-lock Snackbar is checked in semantics text because its exact
  text locator did not expose the visible message reliably.

Backups are ZIP files. The restore picker accepts `.zip`; the archive contains
`manifest.json`, `data.json`, `README.txt`, and `recordings/<id>.wav`. Format version
1 records each recording's byte count and SHA-256 digest. Hosted and independent
disposable local checks verified the story/recording/relationship workflow, ZIP recording
integrity, and fresh-profile restore with actual playback. Hosted completion is
established only by a successful full run against the deployed release: require
exit status zero and `result.json` with `completed: true`, then verify temporary
identity/token cleanup through the protected operator flow. A partial result or
local run alone does not establish hosted completion.

## Anonymous recordings

`anonymous.py` exercises guest capture, automatic text from the pinned public English
speech fixture, preserved typed notes, saved playback, all three daily recording
slots, the fourth-recording sign-in prompt, and raw server duration/quota rejection.
It also tries a fresh recording UUID and spoofed forwarding header after exhaustion.
The daily boundary is UTC. The one-minute automatic-stop attachment is additionally
covered by controller and both story-form regression tests.

The public mode spends the running connection's real daily guest allowance. Prefer
an operator-owned loopback port-forward to the deployed Con backend on port 18083
for this synthetic quota test:

```sh
/home/ekwav/.cache/uv/archive-v0/eq7TXxf37ojESxDq/bin/python deployment/e2e/anonymous.py \
  --output /tmp/con-anonymous-e2e \
  --audio-fixture /run/media/ekwav/Data/dev/lifenizer/e2e/fixtures/speech-sample.wav \
  --api-forward http://127.0.0.1:18083
```

Only transcription calls are forwarded; their actual method, audio body and
headers reach the real deployed backend and its persistent quota store. UI assets
and navigation still use the public HTTPS site. This mode tests a separate effective
IP and leaves the owner's public allowance alone; its result explicitly records
`server_path: isolated_deployed_backend`. It does not establish public ingress IP
forwarding by itself. The public authenticated harness, exact Fleet proxy allowlist,
rendered ingress directives and trusted/untrusted forwarding request tests provide
that separate evidence. No fake transcription or quota response is injected.

The fixture is hash-pinned and must contain the known public synthetic 11-second
speech; owner recordings are refused. Require exit zero, `completed: true` and zero
uncaught errors. Partial runs retain `completed: false`; test quota state expires
naturally rather than being reset through a production bypass.

Alternatively route the entire browser through an owned TLS ingress tunnel:
`--browser-arg='--host-resolver-rules=MAP con.coflnet.com 127.0.0.1:18443'`.
This still verifies HTTPS/SNI and the deployed ingress, with
`server_path: isolated_ingress`. The tunnel's source can share the same effective
quota as a backend tunnel; read status before starting.

Use `--initial-remaining N` to resume from the actual remaining allowance after
an interrupted test. `N=0` runs only exhausted-quota guidance and anti-spoofing
checks; its receipt explicitly records that no recordings were tested in that
run. Duration rejection is checked while allowance remains; exhausted quota takes
precedence afterward. Never reset production quota to obtain a passing receipt.
A resumed completion does not establish three completed recordings in one run.

## Automatic story participants

`people.py` checks person recognition through the actual Flutter web UI, without
entering names in the manual person field. A German story recognizes Jane Smith,
Paul and Eva; Eva is removed before Save. A second English story reuses Jane and
Paul. ZIP exports prove exact person counts, absence of Eva and reused participant
IDs; reload and restore into a fresh browser context preserve those same IDs.
German screenshots cover 390px and 1440px. Any uncaught browser error fails the run.

Build the current app with `flutter build web --release` in `flutter_app`, then run:

```sh
/home/ekwav/.cache/uv/archive-v0/eq7TXxf37ojESxDq/bin/python deployment/e2e/people.py \
  --serve-directory flutter_app/build/web --output /tmp/con-person-local-e2e
```

The harness serves only localhost port 18085, records its owned HTTP server PID,
verifies its exact command before stopping it, and uses the existing isolated
Chromium profile/PID lifecycle. Local checks need no backend and use typed text;
they do not claim speech recognition was verified. No account or secret is needed.

For hosted speech verification, the primary operator creates and cleans up a
protected disposable identity fixture using the existing OpenBao child-session
flow described above. Pass a fictional 16-kHz mono PCM `people-speech.wav` narrating
Jane Smith visiting Uncle Paul and meeting Mother Anna Miller:

```sh
/home/ekwav/.cache/uv/archive-v0/eq7TXxf37ojESxDq/bin/python deployment/e2e/people.py \
  --origin https://con.coflnet.com --fixture /tmp/con-e2e-users.json \
  --audio-fixture /tmp/con-person-e2e/people-speech.wav --output /tmp/con-person-hosted-e2e
```

Hosted recording sends the fictional fixture to real ASR, preserves typed notes,
adds Anna Miller and verifies recording ZIP integrity and actual media playback
before/after reload and fresh restore. It injects no transcription responses.
Require exit zero and `result.json` with `completed: true`, `uncaught_errors: 0`,
and the expected `recorded` mode. Failures print only exception type and static
phase/control names; credentials and token values are never printed.
