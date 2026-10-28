# Relationship Manager

A full-stack application designed to track and manage relationships, people, places, and events, featuring offline-first capabilities and secure cloud synchronization.

## Project Overview

This system is divided into two main components:
* **Frontend (`flutter_app`)**: A cross-platform Flutter client app representing the user interface. It works offline using a local database and synchronizes data when a network connection is available. Data is encrypted prior to sync.
* **Backend (`backend/RelationshipManager.Api`)**: An ASP.NET Core 8 Web API that provides authentication, metadata synchronization, blob storage, and live speech-to-text transcription for stories being recorded. The backend never needs to read user content - blobs are opaque, already-encrypted bytes to it.

Con opens directly into the local app; no account or guest-selection step is required. New users see a short introduction and can start by recording their first story without providing account details or location. Recording starts only after tapping the microphone. Title, people and relationship suggestions are extracted from the transcript and remain editable; other metadata can be added below. Account sign-in remains optional in Settings. Main navigation contains Map, People, Stories and Places; Objects remains available in Settings. On desktop, the sidebar offers the most recently saved story location as a shortcut to add another story there. Grouped map markers show one aggregate story count. A branded HTML loading screen explains the tool before Flutter is ready, includes search/social metadata and no-JavaScript guidance, and offers reload after a startup failure. German browser preferences use German copy; explicit `?lang=de` / `?lang=en` variants keep the loading screen and app language aligned. Reciprocal hreflang links, localized metadata and Open Graph locales identify these variants. After ten seconds the loading status updates honestly and a tip appears; tips rotate every fifteen seconds until the app opens or loading fails.

Story descriptions and recording transcripts automatically suggest people in both story forms. Existing names, aliases and unique first names reuse local records; unfamiliar names are recognized conservatively after German/English human cues such as “meine Schwester Anna” or “my uncle Paul”. Suggestions can be removed, ambiguous names require a choice, and new people are created only when the story is saved. Recognition runs on the device and does not upload transcript text to an additional service. Unintroduced names and pronoun resolution remain outside this first pass.

Record information from a person’s page to capture connections without choosing a location or re-entering that person’s name. Explicit German/English relationship statements also suggest removable connections, including simple relative chains such as “Alex is the brother of Ben, who works at Zeta and is a colleague of Dana”. Repeated recordings reuse the relationship and retain all source stories. Explicit employer, residence, move, profession, hobby, pet, birthday, phone-number and new-car statements are indexed on the relevant person and link back to the original story/recording. “John wohnt in Dorfstraße 17” becomes a removable fact under John with its source story; existing contact addresses are preserved. Existing employers and notes are preserved. This local first pass supports explicit sentence templates, not general pronoun resolution or arbitrary fact extraction.

The [50-case extraction regression set](docs/extraction-suggestion-cases.md) covers address punctuation, fact attribution, bounded same-sentence residence corrections, uncertainty, and the supported fact types. All cases run in the normal test suite. Shared residences attach evidence to both named people without inferring a romantic relationship; pet names do not create people. Facts preserve past/future qualifiers and never overwrite existing contact fields.

Detection also supports “Ben’s mother is Anna”, “Anna, Ben’s sister, works at Zeta”, “Anna and Ben are friends”, and explicit marriage statements. Grandparents, grandchildren, stepfamilies, half-siblings and neighbours use the existing relationship types. Questions, negation and uncertain claims do not produce relationship suggestions; each suggestion retains the original wording as evidence.

Unfinished forms warn before a browser refresh or tab close; in-app back navigation offers Save draft, Discard or Keep editing.

Web startup preloads SQLite while Flutter downloads and initializes the database, account and settings concurrently. Repeat cold/warm browser measurements with `deployment/e2e/load.py`. The app icon source and generator live in `flutter_app/tool/`; run `python3 flutter_app/tool/generate_app_icons.py` with `rsvg-convert` installed to regenerate the web and Android icons.

New unnamed places use the closest mapped street address within 50 metres. The client queries [Photon’s reverse geocoder](https://github.com/komoot/photon/blob/master/docs/api-v1.md) with the selected coordinates and previews the address while choosing a location. Photon uses OpenStreetMap data; its public service has no availability guarantee and requires reasonable request volume. Manually entered names are preserved; opening or moving a place with a generated coordinate name retries its address lookup. Missing addresses or lookup failures retain the localized coordinate fallback.

Recordings offer an explicit training-sample report: preview the shared story text and extracted information, add a correction, optionally include the selected audio, and consent before uploading. Reports are persisted in the server database. Authorized reviewers can export private JSON/WAV datasets with the [training export script](deployment/training/README.md).

### Tech Stack
* **Client:** Flutter / Dart (Local DB: sqflite)
* **API:** C# / .NET 8 / ASP.NET Core
* **Databases/Storage:**
  * **ScyllaDB (Cassandra):** High-performance NoSQL database for structured user metadata and sync entries.
  * **MinIO:** S3-compatible object storage for the encrypted blobs (people, events, files) synced from the client. Storage is optional at start-up; the API still starts and answers 503 on the blob endpoints when it isn't reachable or configured.
* **Infrastructure:** Docker & Docker Compose.

---

## Getting Started for Developing

### Prerequisites
* [Docker](https://docs.docker.com/get-docker/) & Docker Compose (for running the database, object storage, and backend)
* [Flutter SDK](https://docs.flutter.dev/get-started/install) (for running the frontend client)
* [.NET 8 SDK](https://dotnet.microsoft.com/en-us/download/dotnet/8.0) *(Optional: if you plan on debugging the backend locally outside of Docker)*

### 1. Starting the Backend Environment

The entire backend infrastructure (ScyllaDB, MinIO, and the .NET API) is containerized for easy local development.

From the root of the workspace, run:

```bash
docker compose up -d
```

*Note: On first launch, the API itself creates the Cassandra keyspace (and each table, lazily, the first time it's needed) once ScyllaDB is reachable - there is no separate init container for it. `minio-init` still runs once to create the S3 bucket ahead of the first request.*

**Local Services:**
* **ASP.NET API:** `http://localhost:5000`
  * Check the **Swagger UI** for testing endpoints at: `http://localhost:5000/swagger`
  * Liveness: `http://localhost:5000/health` - readiness (checks Cassandra, reports whether S3/transcription are configured): `http://localhost:5000/health/ready`
* **MinIO Storage Console:** `http://localhost:9001`
  * *Username:* `minioadmin`
  * *Password:* `minioadmin123`
* **ScyllaDB:** Port `9042`

### 2. Running the Flutter Client

The Flutter app is configured to talk to your local backend API (`http://localhost:5000`).

Open a new terminal and navigate to the `flutter_app` directory to acquire packages and start the app:

```bash
cd flutter_app
flutter pub get

# To run on the web:
flutter run -d chrome

# To run on an emulator or connected device:
flutter run
```

### 3. Backend Development (Debugging Locally)

If you need to make changes to the C# API and wish to debug it using Visual Studio, Rider, or VS Code (instead of running it via Docker):

1. Spin up only the backing services:
   ```bash
   docker compose up -d scylladb minio minio-init
   ```
2. Navigate to `backend/RelationshipManager.Api` or open `backend/RelationshipManager.sln` in your IDE.
3. Start the project using your debugger or run:
   ```bash
   dotnet run
   ```

Local defaults (Cassandra at `localhost:9042`, MinIO at `localhost:9000`, `ENABLE_DEV_AUTH` off) come from `appsettings.Development.json`; the base `appsettings.json` only holds values safe to ship in every environment (an obvious JWT secret placeholder, no S3/Cassandra connection info). `POST /api/auth/dev` (mint a token for any user id, no real login) only ever works when `ASPNETCORE_ENVIRONMENT=Development` **and** `ENABLE_DEV_AUTH=true` - set the latter in your shell or launch profile if you need it outside `docker compose` (which already sets it).

### 4. Running the Backend Tests

```bash
cd backend
dotnet test RelationshipManager.sln
```

`RelationshipManager.Api.Tests` (NUnit) needs neither Cassandra nor S3 nor a running Docker stack: Cassandra/S3/Firebase/transcription are all substituted with in-memory fakes, and the app is booted directly (via `RelationshipManagerApp.Build`) on a real loopback Kestrel server for the request-level tests.

## Configuration

Every key below can be set via `appsettings*.json` or the matching environment variable (`__` for nesting, e.g. `CASSANDRA__HOSTS`). Booleans accept `true`/`false`. The `Environment Variable` column is the exact spelling a Kubernetes chart (or any other env-var-only deployment) needs to use - verified against each key's actual binding site in code, not just derived mechanically, since .NET's env var provider is case-insensitive but `docker-compose.yml`'s existing usage (the source of truth for the casing already running today) mixes `jwt__issuer`/`jwt__secret` (lowercase, matching the `jwt:issuer`/`jwt:secret` config keys) with `CASSANDRA__*`/`S3__*` (uppercase, matching those config keys).

| Key | Environment Variable | Purpose | Default |
| --- | --- | --- | --- |
| `ASPNETCORE_ENVIRONMENT` | `ASPNETCORE_ENVIRONMENT` | `Development` relaxes JWT-secret and CORS checks and enables Swagger; anything else is treated as production-like. | unset (→ Production) |
| `ASPNETCORE_URLS` | `ASPNETCORE_URLS` | Address(es) Kestrel listens on. | `http://+:8000` in the container |
| `jwt:issuer` / `jwt:secret` | `jwt__issuer` / `jwt__secret` | Signs and validates auth tokens. Outside Development the app **refuses to start** if `jwt:secret` is missing, shorter than 32 characters, or still the shipped placeholder. | placeholder in `appsettings.json` (Development only) |
| `ENABLE_DEV_AUTH` | `ENABLE_DEV_AUTH` | Enables `POST /api/auth/dev`. Also requires `ASPNETCORE_ENVIRONMENT=Development`; the endpoint is a 404 otherwise. | `false` |
| `GOOGLE_APPLICATION_CREDENTIALS` | `GOOGLE_APPLICATION_CREDENTIALS` | Path to a Firebase/Google service account JSON. When set (and the file exists), `POST /api/auth/firebase` verifies real tokens; otherwise it answers `503 sign_in_not_configured`. Read directly from the process environment (not through `IConfiguration`), so this is the one key that has no `appsettings*.json` equivalent. | unset |
| `Cors:AllowedOrigins` | `Cors__AllowedOrigins__0`, `Cors__AllowedOrigins__1`, ... | Array of allowed CORS origins - one env var per index, since `IConfiguration` binds arrays positionally; there is no single-variable/comma-separated form. Empty means no cross-origin access at all. In Development, `localhost`/`127.0.0.1`/`::1` on any port are also allowed (for `flutter run -d chrome`). | `[]` |
| `CASSANDRA:HOSTS` | `CASSANDRA__HOSTS` | Comma-separated Cassandra/Scylla contact points. | `localhost` (Development) |
| `CASSANDRA:KEYSPACE` | `CASSANDRA__KEYSPACE` | Keyspace name; created automatically if it doesn't exist (alphanumeric/underscore only). | `relationship_manager` (Development) |
| `CASSANDRA:USER` / `CASSANDRA:PASSWORD` | `CASSANDRA__USER` / `CASSANDRA__PASSWORD` | Cassandra credentials. | `cassandra`/`cassandra` (Development) |
| `CASSANDRA:REPLICATION_CLASS` / `CASSANDRA:REPLICATION_FACTOR` | `CASSANDRA__REPLICATION_CLASS` / `CASSANDRA__REPLICATION_FACTOR` | Replication used only when creating the keyspace. | `NetworkTopologyStrategy`/`3` in code; `SimpleStrategy`/`1` in Development |
| `CASSANDRA:X509Certificate_PATHS` | `CASSANDRA__X509Certificate_PATHS` | Comma-separated client certificate file(s) for TLS. Production Scylla requires this. | unset (TLS off) |
| `CASSANDRA:X509Certificate_PASSWORD` | `CASSANDRA__X509Certificate_PASSWORD` | Password for the client certificate(s). Required if `X509Certificate_PATHS` is set. | - |
| `CASSANDRA:X509Certificate_VALIDATION_PATH` | `CASSANDRA__X509Certificate_VALIDATION_PATH` | Root CA certificate to pin server validation to, instead of the system trust store. | unset |
| `CASSANDRA:TLS_SERVER_NAME` | `CASSANDRA__TLS_SERVER_NAME` | Expected server certificate name when contact points are IP addresses. Certificate name and CA validation still apply. | unset (driver resolves host name) |
| `S3:ENDPOINT` / `S3:ACCESS_KEY` / `S3:SECRET_KEY` / `S3:BUCKET` | `S3__ENDPOINT` / `S3__ACCESS_KEY` / `S3__SECRET_KEY` / `S3__BUCKET` | S3-compatible blob storage. Provision the bucket before enabling S3; the app checks only that bucket and never lists or creates buckets. S3 is optional: if any of these is blank, or the bucket can't be reached, blob-related endpoints answer `503` instead of failing to start. | MinIO dev values (Development) |
| `S3:USE_PATH_STYLE` | `S3__USE_PATH_STYLE` | Path-style S3 addressing (needed for MinIO). | `true` |
| `Transcription:BaseUrl` | `Transcription__BaseUrl` | Upstream speech-to-text base URL. Empty disables the feature (`503 transcription_not_configured`). | unset |
| `Transcription:Api` | `Transcription__Api` | `asr-webservice` (onerahmet/openai-whisper-asr-webservice, used in production) or `openai` (`/audio/transcriptions`-compatible). | `asr-webservice` |
| `Transcription:Model` | `Transcription__Model` | Model name, `openai` protocol only. | `whisper-1` |
| `Transcription:ApiKey` | `Transcription__ApiKey` | Bearer token, `openai` protocol only. | unset |
| `Transcription:TimeoutSeconds` | `Transcription__TimeoutSeconds` | Upstream call timeout. | `60` |
| `Transcription:DefaultLanguage` | `Transcription__DefaultLanguage` | ISO 639-1 language used when a request doesn't specify one. Empty means auto-detect. | unset |
| `Transcription:MaxConcurrentPerUser` | `Transcription__MaxConcurrentPerUser` | Max transcription segments one user can have in flight at once (`429` beyond it). | `2` |
| `Transcription:MaxSegmentBytes` | `Transcription__MaxSegmentBytes` | Max size of one audio segment, enforced while the body is being streamed in (`413` beyond it). | `5242880` (5 MB) |

## Container image and deployment

Production runs a single container image, built from the root `Dockerfile`, that contains both
the compiled Flutter web app and the backend: the backend serves the web app from `wwwroot` and
answers `/api`/`/health` itself, all on one port. (`backend/RelationshipManager.Api/Dockerfile` is
a separate, backend-only image used by `docker-compose.yml` for local development - it is not
what ships to production.)

### Stages

1. `flutter-base` / `web` - installs the exact pinned Flutter SDK (see the version pin in the
   Dockerfile) and runs `flutter build web --release`. No API base URL is passed at build time:
   the web app is served from the same origin as the API in production, so it should fall back to
   relative (same-origin) requests when none is configured.
2. `build` - `dotnet restore` and `dotnet publish -c Release` of `backend/RelationshipManager.Api`.
3. `test` - runs `dotnet test` for `backend/RelationshipManager.sln` and `flutter test` for the
   app. Pull requests build this stage (see `.github/workflows/ci.yml`); it is not part of the
   final image, so a normal build never pays its cost.
4. Final stage - an ASP.NET Core 8 runtime image with the published backend and the web build
   copied into `/app/wwwroot`, running as a non-root user on port 8000.

### Building and running it locally the way production does

```bash
docker build -t relationship-manager:local .

docker run --rm --name relationship-manager \
  --read-only --cap-drop ALL --security-opt no-new-privileges \
  --user 1654:1654 --tmpfs /tmp \
  -p 127.0.0.1:8000:8000 \
  -e ASPNETCORE_ENVIRONMENT=Production \
  -e Jwt__Secret=<a real secret, at least 32 characters> \
  -e Jwt__Issuer=https://con.coflnet.com \
  relationship-manager:local
```

This starts the API-only first production stage (no Cassandra/S3/transcription configured):
`/health` answers 200 immediately; `/health/ready` answers 503 until Cassandra is reachable and
configured (`CASSANDRA:HOSTS`, `CASSANDRA:KEYSPACE`, ...; see the Configuration table above); S3
and transcription stay optional (their endpoints answer 503 until configured). The image runs
correctly fully read-only, as a non-root user, with all capabilities dropped - no writable paths
were required for this baseline configuration in testing, though `/tmp` is still mounted above as
a defensive `emptyDir`-equivalent (loading a Cassandra client `.pfx` certificate, once configured,
can need a writable temp directory on Linux).

`jwt:secret` is the one setting the app refuses to start without outside Development: it must be
at least 32 characters and not the development placeholder.



While a user records a story, the client sends short audio segments (at speech pauses, with a six-second fallback; WAV PCM 16kHz mono is the primary case; `webm`/`ogg`/`mp4`/`mpeg` are also accepted) and the backend streams each one straight through to a speech-to-text upstream and returns the text - it is a pass-through, not a store.

Sentence cuts use the same Silero v5 `VadIterator` approach as DiaFlutter through its canonical public upstream, [keyur2maru/vad v0.0.7](https://github.com/keyur2maru/vad/tree/28bb26c734e1e5ef6a1c14a07dfcdb7452dcbf93), pinned to commit `28bb26c734e1e5ef6a1c14a07dfcdb7452dcbf93` (MIT, © 2024–2025 Keyur Maru). No private fork source is bundled or needed for builds. The model is copied unchanged from that public commit's `companion-package/silero_vad_v5.onnx` into `flutter_app/assets/vad/`; SHA-256 is `2623a2953f6ff3d2c1e61740c6cdb7168133479b267dfef114a4a3cc5bdd788f`, with its upstream MIT license alongside it. The iterator consumes existing microphone PCM locally and ends an utterance after about 512ms of silence; segments have a one-second minimum to avoid excessive tiny uploads. Continuous speech uses the existing quiet-cut fallback. Every segment must contain locally detected speech before upload; silence is skipped, and audio that could not be classified stays saved for retry. The ASR webservice also receives `vad_filter=true` to filter nonspeech before transcription. The model and ONNX Runtime 1.22 web assets are self-hosted; inference does not send audio elsewhere. Original PCM stays intact, and device-local segment lengths and speech decisions are saved before submission so retries preserve their identities after restart. Record 7 remains the microphone capture dependency; only upstream's PCM iterator is imported, bypassing its Record 6 microphone handler.

* `GET /api/transcription/status` (public) → `{ "available": true|false, "usedSeconds": number, "remainingSeconds": number, "dailyLimitSeconds": 300|1200, "warningAfterSeconds": 180|null, "resetAt": "ISO UTC" }`, so the app can check availability and remaining transcription time when recording is requested.
* `POST /api/transcription/segment` (public; optional Bearer authentication), body = raw audio bytes, `Content-Type: audio/wav`, optional `?language=xx` (two-letter ISO 639-1) → `{ "text": "..." }`.

Every request requires `recordingId=<UUID>&segment=<0..4095>` and valid PCM WAV audio. Guests share five transcription minutes per effective client IP per UTC day; signed-in users receive twenty minutes per account per UTC day. Live and stored-recording recognition send only VAD-positive audio segments; wholly silent segments do not consume time. The server verifies submitted WAV duration rather than trusting client duration claims. Original recordings are retained in full, including silence and any audio not transcribed. There is no guest one-minute wall-clock cap or three-recording limit.

Cassandra compare-and-set reservations enforce the cumulative budget across replicas. Successful transcription commits duration; failed/cancelled requests release it. Retries preserve segment identity and do not charge again; changed bytes under the same identity are rejected. Pending reservations expire after five minutes for crash recovery, and each actor has a generous 4,096-distinct-segment daily safeguard against tiny-upload ledger growth. An invalid Bearer token returns 401 rather than falling back to guest access. Status and successful segment responses expose `usedSeconds`, `remainingSeconds`, `dailyLimitSeconds`, `warningAfterSeconds`, and `resetAt`; successful segment responses also contain `text`.

No quota copy appears on a fresh recording screen. After more than 180 committed transcription seconds, guests see a warning with an optional sign-in action. That action stops capture and saves the local story/audio before authentication. Hard quota responses retain original audio for later retry. The day resets at 00:00 UTC.

Audio and transcript text are never persisted on the server or included in logs. Anonymous successful results may remain in bounded volatile memory for 15 minutes to answer retries without repeating upstream recognition. Cassandra retains only a hashed IP-or-account/day key and recording/segment IDs, hashes, durations and retry metadata, with a two-day TTL. Client audio and photos remain local and are included in backups.

`ReverseProxy:KnownProxies` (indexed environment variables `ReverseProxy__KnownProxies__0`, etc.) must name only trusted ingress peers. The application accepts one overwritten `X-Forwarded-For` hop from those peers; without a configured list, it trusts no forwarding header. Fleet pins the verified nginx node and Cilium host addresses. Update this exact list if ingress node routing changes.

Error responses (all `{ "slug": "...", "message": "..." }`): `503 transcription_not_configured` (no `Transcription:BaseUrl`), `415` unsupported content type (PCM WAV is required), `400 invalid_language`, `429 too_many_requests` (per-user concurrency), `413 segment_too_large`, `502 transcription_failed` (upstream error or timeout), `429 anonymous_daily_limit` (sign in or wait until the next UTC day), `429 transcription_daily_limit` (signed-in daily allowance), `429 recording_segment_limit` (daily request-cardinality safeguard), and `503 recording_quota_unavailable` (retry later or sign in).

## Project Structure

* `/backend/RelationshipManager.Api/` - Source code for the REST backend.
  * `Controllers/` - Auth, Sync, Transcription and health API endpoints.
  * `Services/` - S3, sync, and transcription service logic.
  * `Data/` - Cassandra session/keyspace handling and the per-table stores (`IUserStore`, `ISyncStore`), kept behind interfaces so tests can substitute in-memory fakes.
  * `Auth/` - JWT issuing and Firebase token verification.
  * `Errors/` - The uniform `{slug, message}` error shape.
  * `Http/` - Small HTTP plumbing (e.g. the request-body size limiter used by transcription).
* `/backend/RelationshipManager.Api.Tests/` - NUnit test project; see "Running the Backend Tests" above.
* `/flutter_app/` - Source code for the Flutter mobile/web client.
  * `lib/models/` - Domain logic and classes (Events, Persons, Places, etc.).
  * `lib/screens/` - UI feature views.
  * `lib/services/` - Sub-services managing DB, Sync, Encryption, and HTTP routing.
* `docker-compose.yml` - Defines the orchestration of ScyllaDB, MinIO, and the API.

### Explicit shared-issuer cutover

The existing authority remains configured until reviewed activation. Changing
`Oidc:Issuer` to `https://auth.coflnet.com/auth/realms/con` requires the recorded
UTC `Oidc:IssuerMigrationStartedAt` and verified
`Oidc:MaxAccessTokenLifetimeSeconds`. Only the exact old issuer is additionally
accepted during `start <= now < start + lifetime + 600 seconds`; signature,
audience, expiry, authorized party and verified subject remain mandatory.
Discovery itself must report the exact active issuer. Old tokens must verify
against retained keys from that trusted active discovery endpoint.

Keep these recorded migration settings after old-token acceptance expires. The
old issuer remains the permanent Cassandra account namespace, retaining user IDs
and encryption salts. Equal email addresses never join accounts. A different
existing old/new account for the same verified subject returns 409 without
updating either account. New logins still resolve the canonical account after
the compatibility deadline.

Con bounds machine completion (token exchange, API acceptance and account
verification) with one eight-second deadline, abortable web requests and no HTTP
redirect/code/refresh replay. Native AppAuth separates the human authorization
wait from token completion and passes the SDK nonce and PKCE verifier to its
one-use exchange. The plugin does not expose a native socket-abort API: a timed
out SDK request may finish internally, but its late result is never adopted or
replayed. Origin outage responses are separately bounded by the shared auth edge.
No physical Android/iOS interruption is claimed by the offline SDK tests.

Transient sign-in failure offers a manual retry in two minutes in DE/EN and
keeps local stories, pending changes, previous identity and encryption salt.
Logout clears local app credentials without waiting for an unreachable identity
provider. Tests cover real signed JWT migration/collision/expiry, stored-profile
and queue preservation, native nonce/verifier handoff and eight-second abort.
The real shared-Keycloak and rolling-node browser rehearsals remain deployment
gates rather than mocked-test deployment claims.

Repeat the local browser matrix after serving the built app on loopback:

```sh
PLAYWRIGHT_MODULE=/path/to/playwright/module node flutter_app/test/browser/auth_outage.cjs
```

`AUTH_TEST_BASE` selects the loopback build; `AUTH_TEST_OUTPUT` selects the
report directory. DE/EN desktop/mobile at 200% zoom use mocked auth responses;
requests outside the local build are blocked.

### Packed encrypted synchronization

Sync collapses queued edits to each person, place, object or connection into one
upload of its latest captured snapshot. With `Sync:PackingEnabled=true`, clients
discover support in the existing updates response and send up to 128 records or
4 MiB of ciphertext per request. The server stores these independently encrypted
records in one immutable S3 object. Downloads group records from the same pack
into one storage read and return them in bounded batches. Oversized records use
the existing individual upload/download path. Events remain monthly blobs and
recordings retain their resumable 1 MiB v1 chunks.

No encryption format or Cassandra schema changes are required. Older clients
receive short-lived URLs for their exact encrypted slice; these URLs require a
canonical HTTP(S) origin in `jwt:issuer` and use a separate capability signature
derived from the existing JWT secret. They cannot authenticate as application
JWTs. Ordinary commits cannot supply pack references or another user's keys.

Packed writes default to off. First deploy this compatible reader to every
replica, then enable `Sync__PackingEnabled` through Fleet. Disabling the flag
stops new packed writes but continues reading existing packs. After activation,
rollbacks must retain a pack-capable backend; pre-packing releases cannot read
these objects. Capability-free servers continue using the legacy protocol.

Publication retains the existing per-record commit semantics: a failed batch can
commit a prefix. The client keeps all affected pending rows for retry, and only
acknowledges captured rows after the final index commit succeeds. Edits made
during an upload remain pending. Physical packs reduce S3 writes and client HTTP
requests; logical records still retain their separate database commits. Existing per-record
last-writer behavior and storage retention are unchanged; superseded packs are not
automatically compacted or garbage-collected.

### Transcription and Dia corrections

Con's recording client sends audio to its own `/api/transcription/segment` API,
which retains authentication, anonymous allowance and concurrency checks.
With `Transcription:Api=asr-webservice`, optional `Transcription:DialectBaseUrl`
selects Dia's `/api/Dialect/transcribe` GPU worker queue for German (`de`).
Other languages and automatic detection retain `Transcription:BaseUrl`.
Fleet configures the internal Dia service and exact Con-to-Tab TCP8000 policies;
ordinary transcription does not submit training contributions.

Recordings offer “Correct a sentence for Dia” both after capture and in saved
stories. Selecting a wrong word in the story also opens its sentence with that
exact word selected. The editor changes only this sentence; matching original
audio and unchanged neighboring transcript context stay together for training.
Older recordings are automatically re-transcribed through Con's normal speech
API and allowances; detected byte/time boundaries are saved for future reuse.
Cancellation or failed detection never saves partial boundaries. Existing audio
and story text are preserved.

Original segment text is saved with its byte boundaries as recognition completes,
including before a crash. Corrections reuse these marks without another speech
request; retries recognize only missing segments. Available earlier transcript
text supplies bounded Whisper context without serializing live requests.

The dialect region uses the story's selected map location first, ahead of saved
choices or device GPS. Without a selected place it defaults to a nonempty saved
choice or an already-permitted current device location. Postcode/country remain
editable. A failed map lookup never substitutes an unrelated saved postcode. Suggestions
never overwrite edits and never request location permission automatically.
Users explicitly agree to Dia's current training terms before contributing
anonymously. Clips are capped at 20 seconds so base64 JSON fits Dia's 1MiB public
gateway. Dia's recording reference is shown for deletion requests; the local
device proof and consent receipt persist.
