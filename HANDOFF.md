# Handoff: Relationship Manager (Coflnet/ConUi) rollout

Written for the next Claude Code session. Read fully before acting. Start the session in
`/run/media/ekwav/Data/dev/Con/ConUi-work/integration` (not in `dev/Connections`, which is a
stale Angular clone kept only for reference).

## Approved Fleet publication — 2026-10-03

Owner explicitly approved Fleet pushes and copying the Argo webhook credential
into ConUi Actions. Both are complete:
- Copied the Fleet-managed `argo-events/github-webhook-secret` value to
  `Coflnet/ConUi` Actions `ARGO_WEBHOOK_SECRET` through memory/stdin only.
  Verified secret metadata updated at 2026-10-03T16:58:00Z. No value displayed.
- Merged current Fleet main without rewriting/amending commits, resolved the
  shared routing-test overlap while preserving upstream tests/image pins, and
  pushed `3b21422780b48fab74b2fff022014d9e809b9826` to `Coflnet/fleet:main`.
  Seven Con and 15 Rfind chart tests pass; three relevant Helm lints pass.
- Fleet bundles observe that commit. The live Con HTTPRoute is Accepted with
  ResolvedRefs; public discovery returns HTTP200 with exact issuer
  `https://app.rfind.de/auth/realms/con` and S256 support. Namespace `con` is
  created. Initial namespace/discovery probes ran ahead of reconciliation;
  later probes verified success. No direct patch of managed resources was used.
- Existing Rfind bundle remains Modified due to rfind-core drift predating this
  change (reported 16:13, before Con push at ~17:00); did not alter that workload.

The owner's approval names Fleet only. ConUi source-main push is still held
under the original no-push restriction; an explicit follow-up approval question
is pending. `fleet/con.yaml` remains absent until normal ConUi CI yields a
scanned digest. The application is NOT deployed and deployed E2E has NOT run.
Dedicated bucket-only S3 credentials are also still pending. The previously
reported Fleet-push and webhook-copy approval blockers are now resolved.

## Provisioning request — 2026-10-03

Owner requested provisioning and deployed E2E. Completed live prerequisites:
- Created and verified separate Keycloak realm `con` / client `con-app`. The
  existing RFInD and Wald realm representations remained identical. Password
  reset is disabled until Con SMTP is configured. Generator/verifier includes
  `basic` subject scope, exact callbacks, public code flow/S256, audience `con-api`.
- Legacy Scylla keyspace/user `con` already existed with old tables; left untouched.
  Created isolated `con_stories` keyspace (datacenter1 RF3) and non-superuser
  `con_stories`, with only CREATE/SELECT/MODIFY on that keyspace. New credentials
  were tested successfully over TLS through existing local CQL configuration.
- Created and read-back verified `kv/con/con-backend`, workload policy
  `con-backend`, and `auth/jwt-talos-eu/role/con-backend`. Leaf contains generated
  JWT signing secret, dedicated DB credentials and CA PFX/config under `files`.
  Existing-object checks and CAS-protected writes preserve unrelated fields.
  Repeatable helper: `ansible/scripts/provision-con-openbao.sh`, executed only
  within the required `fleet/openbao/scripts/openbao-local-session.sh` flow.
  Protected eu-cluster predecessor authority minted a nonrenewable 900-second
  exact-task child. On exit self-revocation returned HTTP403; token artifacts
  removed. No raw values were displayed. Local credential/config files removed.
- Created private EU R2 bucket `con-stories` in existing Cloudflare account
  `fd03721f31d7dccb9201acb6d9840d6d`. No public access was enabled. S3 credentials
  are NOT provisioned: existing Wrangler OAuth lacks token-management authority.

Deployment is NOT completed; deployed E2E has NOT run. No Git push succeeded.
Automatic approval review specifically rejected (1) copying the existing Argo
webhook credential to Coflnet/ConUi Actions `ARGO_WEBHOOK_SECRET`, and (2) pushing
Con-only Fleet changes to main because the original no-push instruction remains
an explicit boundary. Async approval questions are pending for the secret copy
and ConUi/Fleet main pushes. Do not bypass these rejections without approval.
A third question requests a protected local credential path for either suitable
Cloudflare token-management authority or Con-only bucket S3 credentials; never
ask for credential values in chat. No unrelated app credentials may be reused.

Ready local work:
- Integration `b36056c`: reusable Con-only realm provisioning and owned synthetic
  user cleanup, 12 tests pass; all callbacks must match regardless of server order.
- Integration `777c71f`: S3 checks only its preprovisioned bucket (bounded object
  listing); removes broad ListBuckets/auto-create. Three real SDK HTTP regressions;
  full backend suite now 105/105 passes.
- Fresh Fleet worktree `/run/media/ekwav/Data/dev/fleet-work/con-provision`, branch
  `con-provision`, based on current upstream (older worktree is shallow/outdated).
  Commits `d49f718a` chart/PSA, `878a3460` exact Con public realm route, `80d8de03`
  enable OIDC/Scylla/readiness and Con-only database-egress exemption. Seven Con
  chart tests, 14 Rfind routing tests and relevant Helm lints pass. Other database
  policy rules/clients compare unchanged. `fleet/con.yaml` deliberately absent;
  image remains placeholder until the normal scanned ConUi CI promotion.
- Fleet auth init image remains digest-pinned; CA distribution automatically
  covers Con. Namespace/registry credential and actual workload rollout remain
  pending Fleet publication. The identity tunnel launched for provisioning was
  recorded and stopped after command-line verification. No synthetic users added.

After explicit publication approval: publish Fleet contract first, configure the
CI webhook secret via memory/stdin, push reviewed ConUi main, verify GitHub plus
Argo OIDC/mandatory scan/digest promotion, then publish the Con GitRepo registration.
Provision bucket-only S3 credentials via protected input, exact origin CORS for
browser GET/PUT, and CAS-patch only S3 config. Enable S3 only after verification.
Test deployed login, map/story/audio, same-account second-browser sync, account
isolation, backup/restore and indexed relationships. Cross-user sharing remains
unimplemented and must not be reported as passing.

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
