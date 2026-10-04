# Handoff: Relationship Manager (Coflnet/ConUi) rollout

Written for the next Claude Code session. Read fully before acting. Start the session in
`/run/media/ekwav/Data/dev/Con/ConUi-work/integration` (not in `dev/Connections`, which is a
stale Angular clone kept only for reference).

## Transcript connections and person information — 2026-10-04

This section supersedes the runtime source/image below. Source `1657ac0d2c0705b996b014e243a7d23627ad9865` is live
at https://con.coflnet.com. GitHub `37164295077`, Argo `promote-rgqf8`, and Fleet
`e7d6260a300db7bf40513b228b879079fac34cd8` passed. Exact image digest `sha256:14c6ea616cbef8a8bd47aace9202adc243ab4cbe363f7c17d1de016551616b8c` is verified with every desired
replica ready, updated and available; generation equals observed generation.

- Person detail offers “Informationen aufnehmen” / “Record information”, presets
  the person and title, and saves without requiring or inventing a location.
- Both story forms derive removable people, connections and person details from
  typed text and recording transcripts, including final tails. Explicit German
  and English sibling, parent/child, colleague, friend, partner and spouse
  templates support simple relative/coordination chains with or without commas.
  Direct “brother of Ben, who…” and possessive “Ben’s brother, who…” resolve their
  different subjects correctly; paired German/English regressions cover this.
- Employer and new-car clauses are indexed on the relevant person with links to
  original stories/recordings. Existing notes and employers are preserved. Repeated
  evidence reuses global edges and adds source story IDs. Removing inferred
  evidence preserves shared sources and manually confirmed connections.
- Extraction is local and conservative. No additional transcript API/model call;
  general pronouns, arbitrary facts, complicated nested discourse and historical
  relationship onset remain outside this first pass. New JSON fields are additive
  and preserve old backups; no SQL migration is required.
- Hosted `deployment/e2e/connections.py` passed real fictional speech on this exact
  deployed image. Public PKCE, microphone capture and real ASR HTTP200 responses
  produced James–Paul siblings, Paul–Dana colleagues, Paul’s employer Google and
  James’s new-car fact. Exactly three people and two edges, both source story IDs,
  no invented place, source navigation, full serialized equality on reload/fresh
  restore, WAV integrity, advancing playback clocks and zero browser errors passed.
  German phone390 and desktop1440 screenshots were reviewed. Independent local
  production-web typed run passed the same data and restoration checks.
- Both disposable Con identities were removed with GET404 proof and their fixture
  removed. Creation and cleanup used narrow, nonrenewable, short-lived Bao children;
  each was immediately revoked, invalid HTTP403 proven, artifacts removed. The
  owned Keycloak tunnel was stopped only after recorded PID/command verification.

Final checks: 542 Flutter gate tests and 117 backend tests pass; analyzer retains
nine baseline issues; release web and debug APK build successfully. The protected
people-screen build/search suffix remains byte-identical to `69a5c97`. Source
commits `b02ae7e`, `3d9667b`, `b7dcded`, `1657ac0`; harness and receipts use
`[skip ci]` and do not alter the deployed runtime. Safe durable evidence:
`/run/media/ekwav/Data/dev/Con/ConUi-work/review-transcript-connections-2026-10-04`. Existing S3/cloud sharing limitations below remain unchanged.

## Automatic transcript people — 2026-10-04

This section supersedes the runtime source/image below. Runtime source
`8d6d5a57517e2c08cc52390be7ef2a2858f8dbf0` is live at https://con.coflnet.com.
GitHub `37161509940`, Argo `promote-l9f44`, and Fleet promotion
`1bca2084c516ea836048d8d1036a1db5271efa35` passed; exact runtime digest
`sha256:c61845d7dfe5d8d9ca1dd370eb3aff6accf95442d0646357b83320027b60f083`
is Ready1 with generation/observed generation 11. Public readiness HTTP200:
Cassandra and transcription true, S3 false.

- Both story forms recognize people from typed notes and recording transcripts,
  including final segment tails. Known names, aliases and unique first names reuse
  existing records. German/English human cues suggest new names; ambiguous names
  offer choices. Suggestions are removable, discarded drafts write no people,
  and final save rereads the current people to avoid duplicates.
- Recognition runs locally without another API/model service. This is a
  conservative first pass: unfamiliar names without human cues and pronoun
  resolution remain unsupported. It adds story-person links, not inferred family
  relationships; those still use the existing relationship UI.
- Person lists and story forms use “People in this story” / “Personen in dieser
  Geschichte”. Database failures retain the draft and show localized retry guidance.
- Deployed `deployment/e2e/people.py` passed with real fictional speech: three ASR
  requests HTTP200, typed notes retained, existing Jane Smith/Paul IDs reused,
  new Anna Miller linked automatically, removed Eva absent. Backup exact person
  counts/IDs and audio checksum, actual playback, reload and fresh-context restore
  passed with zero uncaught browser errors. German390/1440 screenshots reviewed.
- Independent local production-web run passed typed recognition/removal/reuse,
  exact person IDs, reload and fresh restore, zero browser errors. Harness fixes
  use the explicit story-add control and actual checkbox/delete semantics;
  locally served builds can use their exact bundled renderer bytes when CDN
  startup stalls. No ASR responses are injected.

Both synthetic Con identities were removed with GET404 verification; the credential
fixture was removed. Creation and cleanup used the required narrow, short-lived,
nonrenewable Bao child flow; each child was immediately revoked, invalid HTTP403
proven and token artifacts removed. This task’s owned Keycloak tunnel was stopped
only after verifying its recorded PID/command; browser/server artifacts are gone.

Checks: 506 Flutter gate tests pass (diagnostic memory tests excluded),
117 backend pass; analyzer retains nine baseline issues; web release and debug
APK succeed. Protected people-screen build/search suffix remains byte-identical
to `69a5c97`. Small feature commits `2b79309` and `8d6d5a5`; harness/docs receipts
use `[skip ci]` and do not change Docker inputs or the verified runtime.

Safe durable evidence: `dev/Con/ConUi-work/review-person-recognition-2026-10-04`.
Previous feature evidence remains in `review-features-2026-10-04`.
Cloud storage/sync/sharing limitations from the receipt below remain.

## Guest recording, photos and calendar follow-up — 2026-10-04

This section supersedes the runtime and transcription state in the older receipt.
Runtime source `4b1933b2b922c85e91d625e18abc9a7d2b39e8ac` is deployed at
https://con.coflnet.com. GitHub `37156695138` and Argo `promote-7pgdj` passed
OIDC verification, mandatory scan and promotion. Exact digest
`sha256:79ab865de1cf72b4f5ede3ad74059626de23ef948ffbf95654b452f64517a545`
and deployment generation 10 / observed generation 10 / Ready1 verified.
Public readiness is HTTP200: Cassandra and transcription true, S3 false.

- Anonymous recordings now use actual Whisper transcription. Server-side
  Cassandra CAS limits three recording IDs per effective IP per UTC day and
  validates cumulative PCM WAV duration <=60 seconds. Retries reuse identical
  recording/segment bytes; signed-in users retain the existing longer limit.
  Forwarding is accepted only from the exact verified ingress proxy addresses.
  Fleet `3ef86101` enables Whisper with a Con-only TCP9000 policy;
  `0f9e798d` configures the four verified proxy/source addresses. No broad trust.
- Guest UI explains the allowance before capture, automatically stops at one
  minute while retaining the attached audio, and blocks exhausted quota before
  microphone capture. Typed stories/photos remain available. German/English
  errors explain sign-in, tomorrow, shorter recordings, microphone permissions,
  offline retry, missing originals, and backup recovery. Final transcript tails
  and out-of-order segment answers no longer lose or reorder notes.
- Both story forms accept local photos. Original bytes survive reload and ZIP
  backup/restore with SHA-256 verification; thumbnails open the original viewer.
  Photos are local only: cloud attachment transfer remains unimplemented.
- Stories calendar has a year overview with counts and direct previous/next-year
  controls alongside month navigation. Historical years and narrow German layouts
  have regression coverage. Phone390 and desktop1440 screenshots reviewed.
- Full public hosted E2E passed: two actual PKCE accounts, account isolation,
  authenticated transcription HTTP200, map story/participant/relationship,
  actual playback, photo picker/original viewer, calendar counts/navigation,
  ZIP original-photo/audio integrity, reload and fresh-profile restore. Zero
  uncaught browser errors. Independent production-web photo E2E also passed.
- Guest public checks proved actual speech transcription with typed notes intact,
  three allocated daily slots, actual 61-second WAV rejection HTTP413 before
  exhaustion, and two subsequently saved recordings whose playback clocks advanced.
  The first run incorrectly read an inactive semantic input, although the canvas
  showed the transcript. A resumed run's last assertion inspected an already
  disposed older audio element. Corrected active-player verification separately
  passed two successive restored playbacks. Final exhausted-quota public E2E
  passed: pre-capture German guidance, text/photos still usable, fresh UUID plus
  spoofed forwarding header HTTP429, zero uncaught errors. This is aggregate
  evidence, not a claim of an uninterrupted three-recording E2E pass. No quota
  reset/bypass was performed; today's real test connection allowance is consumed.
- Browser harness fixes wait for Flutter editing activation, refocus inactive
  transcript inputs, select actual roles across responsive/restore transitions,
  and account for merged photo labels and overlapping semantic click targets.
  `--initial-remaining 0` explicitly verifies quota-only continuation.
- Two owned synthetic identities deleted with GET404 verification; fixture removed.
  Cleanup used a narrow short-lived nonrenewable Bao child through the approved
  wrapper; revoked, invalid HTTP403 proven and artifacts removed. All owned tunnels
  stopped by verified recorded PID; exact interrupted browser profile removed only
  after proving its PID absent. Synthetic API rows remain intentionally.
- A kubectl JSONPath error dumped a workflow containing a short-lived CI OIDC token.
  Expiry was verified without printing it again; it is expired. No long-lived
  credential was printed. Raw workflow/token data is excluded from evidence.

Final runtime checks: 479 Flutter pass, two diagnostic memory skips, 117 backend
pass; analyzer retains nine baseline issues; release web and debug APK succeed.
Fleet offline chart checks pass7 and Helm lints pass. Protected people-screen
build/search suffix remains byte-identical to `69a5c97`. Follow-up harness/docs
commits use `[skip ci]`: no Docker inputs change, retaining the scanned exact image.

Safe durable evidence: `dev/Con/ConUi-work/review-features-2026-10-04`.
Remaining: protected Con-only R2 credentials, encrypted cloud-sync E2E,
cross-user sharing and cloud photo transfer. Existing approval is sufficient for
scoped Con provisioning; do not reuse another application's storage credential.

## Live rollout and hosted verification — 2026-10-03

This receipt supersedes all historical no-push, approval and readiness blockers below.
Owner approved rollout pushes across affected repositories, the Argo credential
copy, `rfind-demo/regcred` into `con/regcred`, and the exact Con-only TCP10283
OpenBao proxy rule. These approvals are resolved. Never amend or use broad process
kills; retain the protected people search region and scoped OpenBao flow.

- Con is Ready at https://con.coflnet.com. Runtime source
  `cf1f8ea8a0613f0c4074d2c6e1c3a159f635a509` passed GitHub run `37151516502` and
  Argo `promote-h9q7l`: OIDC verification, mandatory image scan and promotion.
  Fleet image promotion `47224c97` pins
  `sha256:4114b3d316450930f22ba806337cc40bb742791a9cfee6afb98b3b70db577631`.
  Exact `con/con-con-chart` image and observed generation verified after rollout;
  HTTPS readiness is HTTP200, Cassandra true, S3/transcription false.
- Fleet checkout is `dev/fleet-work/con-provision`, branch `con-provision`.
  `fleet/con-app.yaml` registration resolves the reserved `con.yaml` checkout
  failure. Fleet `4e132d5c` adds only namespace `con` / app label `con` to the
  existing OpenBao proxy rule. Live rule and successful init/token revocation
  verified. Registry copy/readback used memory only; no values displayed.
- Dedicated Keycloak realm `con`, public PKCE client `con-app`, issuer
  `https://app.rfind.de/auth/realms/con`, audience `con-api`, exact callbacks and
  `basic` subject scope are live. Browser and actual backend discovery/JWKS work.
  Shared RFInD/Wald realm representations remain unchanged; Con SMTP/reset is off.
- Legacy Scylla `con` is untouched. Dedicated `con_stories` keyspace uses
  datacenter1 RF3; nonsuperuser has CREATE/SELECT/MODIFY only there. Public
  leaf-only certificate identity `sky-client` is verified against the pinned CA;
  wrong name/root and expired leaf are rejected by real TLS regressions.
- Exact OpenBao leaf `kv/con/con-backend`, `con-backend` policy and
  `auth/jwt-talos-eu/role/con-backend` are live. Workload init mounts memory-only
  files and proves token revocation. Con config changes use ansible helpers and
  CAS patches preserving other fields/CA. Protected predecessor authority was
  used only through `openbao-local-session.sh` to mint narrow nonrenewable child
  tokens. Every session revoked its child, proved HTTP403 and removed artifacts.
- Hosted E2E completed successfully on the exact final image: desktop 1440x900
  and phone 390x844 real PKCE, separate accounts/salts/device visibility, map story
  creation, participant and separately indexed friend relationship, actual audio
  clock playback, ZIP/WAV byte-count/SHA-256/header integrity, account/local-audio
  reload, and fresh-profile restore with playback/relationships. Zero uncaught
  browser errors. S3-unconfigured HTTP503 and encryption-locked sync feedback verified.
  Cloud sync, cross-user sharing and native interactive login were not tested.
- E2E exposed two app defects, now fixed with reproducing regressions: both Save
  actions wait for recording finalization; Settings checks mounted before reading
  context in its post-restore sync refresh. Successful restore returns directly
  to the map and disposes Settings. The harness follows that actual navigation.
- Temporary identities are deleted with GET404 verification. Keycloak initially
  dropped the unmanaged ownership attribute; both fixture passwords were proven
  through real PKCE against the recorded OIDC subject IDs, then an admin-only
  managed `con.e2e` attribute was added only to Con's profile and markers restored
  only on those exact identities before unchanged strict cleanup. A fresh marked
  create/readback/cleanup cycle also passed. Fixture credentials, ownership proof,
  browser profiles/PID artifacts and own verified Keycloak tunnel are removed.
  Synthetic E2E API account/device rows remain; no arbitrary application data deleted.
- Argo credential copy to Actions `ARGO_WEBHOOK_SECRET` is complete, metadata
  verified without printing values. Ansible Con-only storage commit `7a02aa3` is
  published. Unrelated ansible/Rfind work was not staged or pushed wholesale.
- Private EU R2 bucket `con-stories`, public access off, exact Con-origin GET/PUT
  CORS readback and HTTP204 preflight verified. Durable Con-only S3 credentials
  remain missing; protected input-file path requested. Never reuse DNS or another
  application's S3 key. `ansible/scripts/provision-con-storage.sh` CAS-patches
  only S3 fields from a protected file. S3 stays disabled.

Final checks: five consecutive Flutter gate passes (452 in runs 1–3; 453 including
Settings regression in runs 4–5), two diagnostic RSS tests skipped by default;
109 backend, 16 realm/provisioning and 3 storage-helper tests pass. Analyzer has
nine unchanged baseline findings; final web release and debug APK build successfully.
Docker test stage runs the same plain `flutter test` gate. People-screen build/search
suffix remains byte-identical to `69a5c97`. Final follow-ups change only operations
scripts and receipts, not Docker inputs; `[skip ci]` retains the already scanned,
E2E-tested runtime. Runtime changes require normal scan/promotion.

Safe durable evidence: `dev/Con/ConUi-work/review-deployed-2026-10-03`, including
`hosted-e2e.json`, synthetic ZIP, deployment/cleanup receipts and final check logs.
Credentials, browser profiles and raw OAuth URLs/tokens are excluded.

Next: obtain protected Con-only R2 credentials, CAS-patch S3 fields, enable the
Con chart gate and matching narrow endpoint egress, then test encrypted cloud
sync. Cross-user sharing and non-recording attachment transfer remain unimplemented.
Owner decisions on original duplicate add controls and rotating `tab`/`ane`
Scylla passwords remain outside this rollout's resolved approvals.

The remaining sections are historical snapshots; their no-push/unprovisioned
statements do not describe the current rollout.

## Shared identity follow-up — 2026-10-03

This section supersedes the earlier missing-authentication/configuration blockers.
RFInD's `docs/SHARED-IDENTITY.md` already designates its Keycloak server for other
projects. Con now has a prepared separate realm `con`, public PKCE client `con-app`,
issuer `https://app.rfind.de/auth/realms/con`, API audience `con-api`, and exact
web/native callbacks. See `deployment/keycloak/README.md`. The generator includes
Keycloak's `basic` scope: real browser testing caught missing `sub` without it.
No Firebase project or additional owner-supplied identity configuration is needed.

Implemented release web/Android sign-in, single-use/expiring browser state and PKCE,
verified account/salt adoption, and backend discovery/JWKS signature/issuer/audience/
client checks. Login and encryption passwords remain separate. Sync keys bind to
account and salt; session checks stop changed-account requests and subsequent state
updates. A full-sync request no longer clears the persisted cursor before success.
Already-issued storage operations cannot be rolled back by these session checks.

Fleet `con-rollout` local commit `a23be5f` replaces hand-created Con JWT/Scylla
Secret references with the prepared exact `kv/con/con-backend` leaf, JWT workload
role, verified TLS init fetch, in-memory config files, and immediate token revocation.
Stage gates override runtime JSON; OIDC requires persistent Scylla. Con-only OpenBao
updates through ansible and the protected narrow child-token flow remain authorized;
no live secrets/roles were read or changed. `regcred`, trusted CA distribution,
Con storage and scoped leaf/role provisioning still need execution before rollout.
RFInD shared-identity registry commit `21f10ec` is local only on its existing master.

Local browser verification used disposable Keycloak 26.7.3 and the real Con API
with in-memory account/sync stores. German phone/desktop login and account screens
fit; PKCE login and repeated login succeed, account ID/salt stay stable, callback
parameters are removed, and both existing stories plus recordings remain local.
This does not verify production Cassandra/S3, shared Keycloak deployment, native
interactive login, or deployed multi-user E2E.

Verification: 450 Flutter tests pass with two memory skips; 102 backend tests pass;
analyzer has the same nine baseline issues; production web release (without the
local HTTP OIDC define) and debug APK build successfully. The merged Android
manifest contains the `com.coflnet.con` AppAuth receiver. Four realm tests and six
Fleet offline tests plus Helm lint pass. Final sync-focused checks pass 11/11;
the broader affected sync suites passed 38/38. The full gate ran before redundant
post-response wrapper checks were removed; the final focused run covers that
simplification. Durable safe evidence is in
`/run/media/ekwav/Data/dev/Con/ConUi-work/review-auth-2026-10-03`; credentials, raw
callback logs and browser profiles are excluded. Local review processes stopped.

Local integration commits: `97dedd4` backend verifier/config, `a167971` Flutter
PKCE/login, `165ad6d` realm generator, `d7bd8b4` sync session guards; all include
the requested co-author trailer.

Nothing was pushed or applied to the cluster. Cross-user sharing and non-recording
attachment transfer remain unfinished. Rollout and deployed E2E require approval.
The owner's checkout and protected people-screen build/search region are unchanged.

## Verification update — 2026-10-03

This section supersedes the original handoff state and TODO status below. Work remains on
`integration/stories-map-rollout`; 17 incremental commits were added (83 ahead of `origin/main`
including this handoff commit), all with the requested trailer.
Nothing was pushed, amended, or deployed. Fleet and the owner's checkout are untouched.

Completed:
- Backup gate: deterministic 200 MiB streaming write/restore buffer checks (maximum 4 MiB),
  whole-file reads rejected. RSS checks retain the `memory` tag and skip by default. Docker runs
  the identical plain `flutter test` gate. Five consecutive runs passed (384 tests each at that point).
- Playback: instrumented actual media objects over CDP, including detached `Audio` elements;
  absence of a DOM `<audio>` is expected. Validated canonical WAV headers and PCM lengths.
  Normal, tab-crash recovered, and backup-restored recordings all advance in headless Chromium.
  A plain static audio page plays identical bytes in headless, muted-headless, and visible Chromium.
  Original/restored SHA-256: `8767d7fb698ce1b7c865289f81dad7b39006b4a88159f0e02986695ad259c673`.
- Source-mapped profile identified a disposed people-screen reload after returning from a detail
  route across the phone/desktop breakpoint. Added a mounted guard and reproducing regression test.
  The entire `persons_screen.dart` build/search region remains byte-identical to `69a5c97`; direct
  comparison from `Widget build(BuildContext context)` through EOF passes (the only edit is a
  mounted guard in `_loadPersons`, above that region).
- German review covers phone 390x844 and desktop 1440x900: map, people, stories, places, objects,
  quick add, recording, story/person detail, relationships/graph, settings, and backup/restore.
  Fixed German unnamed-place defaults, sibling sentences, narrow graph title, nearby-place chip
  wrapping, and place-hint overlap with attribution. Existing saved English place names remain data.
  The protected persons search hint and owner-pending duplicate add controls are unchanged.
- Stories expose separately indexed relationships with the originating story/date preselected.
  Main-screen FAB navigation and sync feedback now report actual offline/password/error states.
- New sync ciphertext uses PBKDF2-HMAC-SHA256 (600,000 iterations) and AES-256-GCM with fresh
  nonces in versioned authenticated envelopes. Legacy decryption remains read-compatible; legacy
  ciphertext has no authentication until rewritten. All participating clients must be upgraded.
- Backend commits validate authenticated-owner blob keys. Failed uploads/commits/downloads keep
  pending work/cursors for retry; tombstones apply without download or requeue loops.
- Original recordings sync in independently authenticated 1 MiB chunks, verified by canonical WAV
  header, size, and whole-file SHA-256 before import. Conflicting originals are preserved. Text-only
  edits reuse committed chunks. Explicit permanent deletion drops audio references from tombstones.
- Further source-mapped review reproduced nonfinite map zoom for two places at the same coordinates.
  Auto-fit now caps zoom at 14; a real MapScreen regression fails before and passes after the fix.
- Chromium auto-loaded KDE/Plasma extension `cimiefiiaegbelhefglklhhakcgmhkai`; its
  `page-script.js:182` removes/replays detached Audio elements and caused intermittent AbortError.
  Final browser checks disable extensions. This is an environment issue, not invalid WAV data.
- Rejected playback could propagate an empty uncaught AbortError. Player controls now show the
  localized error, late sources are released, and URL revocation waits for media disposal. Six
  lifecycle/control regressions all fail before and pass after this fix.
- Browser recording streaming/finalization uses bounded IndexedDB pages and per-chunk transactions.
  Two real-Chromium IndexedDB tests verify multi-page reads with asynchronous consumers and cleanup.

Final verification: 424 Flutter tests pass, two RSS tests skipped; 70 backend tests pass; real
IndexedDB browser tests 2/2 pass; analyzer has the same 9 baseline issues; release web and debug APK
build successfully. The final release opens colocated places without an uncaught exception.
With browser extensions disabled, playback advances normally; a controlled rejected play displays
German feedback without an uncaught exception. The release UI still supports local use only.
An earlier final attempt failed two deletion-test I/O waits and a 30-second crypto-test timeout;
these harness issues were fixed and the complete gate passed afterward. Logs retain both attempts.

### Earlier remaining requirements (superseded by shared identity follow-up)

The app is NOT ready to claim secure sharing between users or deployed end-to-end verification:
- Release login currently offers local use only. Production Firebase sign-in configuration is missing;
  the debug login form is not a production account flow. AuthService's Firebase-token exchange is
  currently unused by release UI. Owner must identify Con's Firebase project/public web+Android
  config, enabled sign-in provider, authorized domain, and backend verifier identity. If using OIDC
  instead, provide the Con issuer and public client ID. Other Coflnet projects are not interchangeable.
- Current sync is same-account only. Cross-user recipient authorization, grants/revocation, and key
  exchange remain unimplemented and must be completed and independently tested after identity setup.
  Non-recording attachments still need an equivalent blob-transfer path for cloud sharing.
- Fleet still references hand-created con Secrets. Con-scoped OpenBao updates via ansible are
  authorized, but no authoritative existing Con KV leaf or workload OpenBao-to-Secret wiring was
  found. Do not invent a path or use broad admin credentials. Read the current leaf, CAS-patch only
  required fields with a short-lived narrow child token, revoke/prove invalid/remove artifact.
  No secrets were read or changed during this verification session.
- Stage 1 needs `con-secrets.jwt_secret` (at least 32 characters) and `regcred`; enabling stage 2 also
  requires `scylla-credentials`, `scylla-pfx`, and `scylla-config`. Scylla/transcription remain disabled.
- Preserve the explicit no-push/no-cluster-mutation boundary. Rollout still requires owner approval;
  deployed multi-user E2E remains pending. The `tab`/`ane` password-rotation decision remains with owner.

Durable review evidence (logs, screenshots, synthetic WAV/backup fixtures, CDP tooling) is outside
`/tmp`, at `/run/media/ekwav/Data/dev/Con/ConUi-work/review-2026-10-03`. Browser profiles are excluded.
Raw `browser-events.jsonl` repeats historical errors whenever CDP Runtime is enabled; deduplicate by
exception timestamp and use fresh page contexts before interpreting the log as new failures.

## Product and goal
Flutter app (`flutter_app/`, web + Android) with an ASP.NET 8 backend (`RelationshipManager.Api`).
Purpose: tap a place on a map, record a relative telling what happened there, keep the original
recording, listen back later; relationship graph explorable from any person; backup and restore
including recordings. Audience: German-speaking, often older, non-technical. German uses formal "Sie".

## Original handoff — repositories and branches (historical)
| Path | Branch | State |
|---|---|---|
| `dev/Con/ConUi-work/integration` | `integration/stories-map-rollout`, 66 commits ahead of `origin/main`, nothing pushed | All features merged. Last verified: 368 Flutter tests + 54 backend tests pass; `flutter analyze` 9 old issues (baseline, none new allowed). |
| same tree, uncommitted | `Dockerfile`, `flutter_app/README.md`, `flutter_app/test/backup/large_recording_test.dart`, new `flutter_app/dart_test.yaml` | Half-finished attempt to isolate the flaky memory test (see TODO 1). |
| `dev/fleet-work/con` | `con-rollout`, 4 local commits, not pushed | Chart reworked into one deployment, `con` namespace in pod security list, chart registered in Fleet, network policies to scylla and whisper-trained. |
| `dev/Con/ConUi` | owner's checkout | Has the owner's UNCOMMITTED work (contacts import in `persons_screen.dart`, one line in `AndroidManifest.xml`). Never touch. In the integration tree the search-field region of `persons_screen.dart` `build()` must stay byte-identical so it merges cleanly. |
| `dev/Connections` | `main`, dirty | Stale Angular clone. Ignore. |

Rules from the owner: small incremental commits on the integration branch were explicitly requested
(subject in imperative, `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` as last line; one
earlier commit `4d06465` lacks the trailer, left as is, never amend/rebase/stash). Never push. Never
mutate cluster state; Fleet-managed resources only via the fleet repo. Read `fleet/argo-workflow/CI.md`
before building/publishing.

## Original handoff — TODOs (historical; see update above)
1. **Make the test gate reliable.** `test/backup/large_recording_test.dart` measures process RSS and
   fails ~1 in 5 even alone with `--concurrency=1`. Plan: add deterministic tests (fake source serving a
   ~200 MB recording as chunks, record largest buffer on write and restore paths, assert <= 4 MB bound,
   assert the whole-read method is never called); keep RSS tests tagged `memory` but skipped by default
   (`dart_test.yaml` tag `skip`, verify a plain `flutter test` really skips them); Dockerfile
   `flutter-test` stage runs exactly the gate suite; README documents the manual memory run. Decide what
   to keep of the uncommitted files. Run the gate 5 times; must pass 5/5. Commit.
2. **Prove browser playback or find the defect.** Play button toggles but position never advanced in
   headless Chromium; no `<audio>` element found in DOM; playback worked on the Android emulator.
   Method: `flutter build web --profile --source-maps --no-web-resources-cdn`, serve `build/web` on a
   free 127.0.0.1 port, Chromium with remote debugging and own `--user-data-dir`, inject via
   `Page.addScriptToEvaluateOnNewDocument` wrapping `HTMLMediaElement.prototype.play/load`, `src`
   setter, `Audio`, `createElement('audio')`, `AudioContext`, `URL.createObjectURL/revokeObjectURL`.
   Record with fake mic flags (`--use-fake-ui-for-media-stream --use-fake-device-for-media-stream
   --use-file-for-fake-audio-capture=<16 kHz mono 16-bit WAV>`), then read src/readyState/networkState/
   error/duration/currentTime/paused and play() promise result; fetch the blob URL and validate the
   44-byte WAV header and MIME type. Control: a plain static `<audio>` page with the same bytes.
   Compare headless vs `--mute-audio` vs `xvfb-run` non-headless. Test 3 recordings: normal, recovered
   after closing the tab mid-recording, restored from backup into a fresh profile. Read how
   `audioplayers_web` plays `UrlSource`. Fix with regression test if it is an app defect.
   Reusable scratch files: `scratchpad/playback-check/cdp.js` (dependency-free Node CDP client), `smoke.js`.
3. **Console error.** One `[SEVERE] main.dart.js` entry with empty message once per interactive
   session, not on idle load. Capture `Runtime.exceptionThrown`, `Log.entryAdded`,
   `Runtime.consoleAPICalled` with stacks against the source-mapped build while walking all screens.
   Fix with regression test if app defect.
4. **German screenshot review** at 390x844 and 1440x900 with `--lang=de`: map, quick add idle and
   recording, place sheet, story detail, person detail with relationships, graph, add connection dialog,
   settings, backup. Fix English leftovers, truncation, overflow. Known deliberate English: OSM
   attribution (must stay), persons search hint (owner's merge area).
5. **Final checks**: `flutter analyze` (no new issues), gate suite, `flutter build web --release
   --no-web-resources-cdn`, `flutter build apk --debug`, backend `dotnet test`.
6. **Rollout** (only after 1 to 5 and owner approval): push integration branch -> PR to ConUi main
   (shared CI builds, Argo scans/publishes and pins the image in Fleet); push `con-rollout` in fleet.
   BLOCKED on the owner: two hand-created Secrets in namespace `con` (Scylla credentials and JWT
   secret) need the owner's explicit "approved" or the owner creates them. Ask before anything.

## Owner decisions still pending (do not decide yourself)
- The two `con` Secrets above.
- People and stories lists show "add" twice (last list row + FAB); original design, left as is. Objects list does not.
- Consider rotating Scylla passwords of `tab` and `ane`: a read-only cluster agent printed Secret contents into its transcript.

## Incidents and hard process rules for agents
- An agent ran `kill -9 $(pgrep -f "9333")` and killed VS Code helper processes (2026-09-29 ~00:19).
  Rule: never `pkill`/`killall`/`kill $(pgrep ...)`. Record PIDs at launch in the scratchpad, verify
  `/proc/<pid>/cmdline` (own `--user-data-dir` path) before `kill`, TERM first. Bind servers to 127.0.0.1
  on a port checked free with `ss -ltn`.
- Two agents were stopped by declined permission prompts; confirm with the owner before relaunching.
- Scratchpad of the old session (`/tmp/claude-1000/.../e90b4bda.../scratchpad`) holds `final-e2e/`
  screenshots + `RESULTS.md` and `playback-check/`; it disappears on reboot and will not be in the new session.

## Machine facts
Flutter 3.44.4; only .NET 10 SDK installed while backend targets net8.0 (`DOTNET_ROLL_FORWARD=LatestMajor`);
Chromium at `/usr/bin/chromium`; Node 22+; Docker available; port 18000 is taken by an unrelated local process.
Use `implementer` agents for coding, `scout` for searching, `cluster-explorer` (read-only, explicit context) for cluster questions.
