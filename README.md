# Relationship Manager

A full-stack application designed to track and manage relationships, people, places, and events, featuring offline-first capabilities and secure cloud synchronization.

## Project Overview

This system is divided into two main components:
* **Frontend (`flutter_app`)**: A cross-platform Flutter client app representing the user interface. It works offline using a local database and synchronizes data when a network connection is available. Data is encrypted prior to sync.
* **Backend (`backend/RelationshipManager.Api`)**: An ASP.NET Core 8 Web API that provides authentication, metadata synchronization, and chunked blob storage.

### Tech Stack
* **Client:** Flutter / Dart (Local DB: sqflite)
* **API:** C# / .NET 8 / ASP.NET Core
* **Databases/Storage:**
  * **ScyllaDB (Cassandra):** High-performance NoSQL database for structured user metadata and sync entries.
  * **MinIO:** S3-compatible object storage for storing binary blobs and encrypted data chunks.
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

*Note: On the first launch, initialization containers (`scylla-init` and `minio-init`) will automatically run to create the required keyspace, tables, and S3 buckets.*

**Local Services:**
* **ASP.NET API:** `http://localhost:5000`
  * Check the **Swagger UI** for testing endpoints at: `http://localhost:5000/swagger`
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
   docker compose up -d scylladb minio scylla-init minio-init
   ```
2. Navigate to `backend/RelationshipManager.Api` or open the root directory in your IDE.
3. Start the project using your debugger or run:
   ```bash
   dotnet run
   ```
The application will map to configurations in `appsettings.Development.json` which are already set to point to `localhost:9042` (ScyllaDB) and `localhost:9000` (MinIO).

## Project Structure

* `/backend/RelationshipManager.Api/` - Source code for the REST backend.
  * `Controllers/` - Auth and Sync API endpoints.
  * `Services/` - S3 Service logic and Sync Metadata logic.
* `/flutter_app/` - Source code for the Flutter mobile/web client.
  * `lib/models/` - Domain logic and classes (Events, Persons, Places, etc.).
  * `lib/screens/` - UI feature views.
  * `lib/services/` - Sub-services managing DB, Sync, Encryption, and HTTP routing.
* `docker-compose.yml` - Defines the orchestration of ScyllaDB, MinIO, and the API.
