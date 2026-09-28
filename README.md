# Relationship Manager

A full-stack application designed to track and manage relationships, people, places, and events, featuring offline-first capabilities and secure cloud synchronization.

## Project Overview

This system is divided into two main components:
* **Frontend (`flutter_app`)**: A cross-platform Flutter client app representing the user interface. It works offline using a local database and synchronizes data when a network connection is available. Data is encrypted prior to sync.
* **Backend (`backend/RelationshipManager.Api`)**: An ASP.NET Core 8 Web API that provides authentication, metadata synchronization, blob storage, and live speech-to-text transcription for stories being recorded. The backend never needs to read user content - blobs are opaque, already-encrypted bytes to it.

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
| `S3:ENDPOINT` / `S3:ACCESS_KEY` / `S3:SECRET_KEY` / `S3:BUCKET` | `S3__ENDPOINT` / `S3__ACCESS_KEY` / `S3__SECRET_KEY` / `S3__BUCKET` | S3-compatible blob storage. S3 is optional: if any of these is blank, or the bucket can't be reached, blob-related endpoints answer `503` instead of failing to start. | MinIO dev values (Development) |
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



While a user records a story, the client sends short audio segments (~6s, WAV PCM 16kHz mono is the primary case; `webm`/`ogg`/`mp4`/`mpeg` are also accepted) and the backend streams each one straight through to a speech-to-text upstream and returns the text - it is a pass-through, not a store.

* `GET /api/transcription/status` (authenticated) → `{ "available": true|false }`, so the app can show up front whether live text will work.
* `POST /api/transcription/segment` (authenticated), body = raw audio bytes, `Content-Type` set to the audio format, optional `?language=xx` (two-letter ISO 639-1) → `{ "text": "..." }`.

**Privacy is a hard requirement, not just a preference:** audio is never written to disk or stored anywhere, transcript text is never stored, and logging never includes audio content or transcript text - only sizes, durations and status codes.

Error responses (all `{ "slug": "...", "message": "..." }`): `503 transcription_not_configured` (no `Transcription:BaseUrl`), `415` unsupported content type, `400 invalid_language`, `429 too_many_requests` (per-user concurrency), `413 segment_too_large`, `502 transcription_failed` (upstream error or timeout).

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
