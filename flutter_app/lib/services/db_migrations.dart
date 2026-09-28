import 'package:sqflite_common/sqflite.dart' as sqflite_common;

/// A single forward-only migration step that brings the schema from
/// [version] - 1 to [version].
///
/// Migrations are the single source of truth for the schema: a fresh
/// install runs every migration in order (see [DatabaseService._onCreate]),
/// and an upgraded install runs only the migrations after the version it
/// was already at (see [DatabaseService._onUpgrade]). This guarantees a
/// fresh install and an upgraded install always end up with the exact same
/// schema.
class Migration {
  final int version;
  final Future<void> Function(sqflite_common.DatabaseExecutor db) up;

  const Migration({required this.version, required this.up});
}

/// Ordered list of every schema migration this app has ever shipped.
/// Append new migrations at the end with the next version number; never
/// edit or remove an already-released migration.
final List<Migration> dbMigrations = [
  const Migration(version: 1, up: _migration1CreateBaseSchema),
  const Migration(version: 2, up: _migration2CreateLocalRecordingsTable),
];

/// The schema version the app currently ships. Equal to the highest
/// migration version.
int get latestDbVersion => dbMigrations.last.version;

// ==================== Migration 1: base schema ====================
// This is the schema the app shipped with before migrations existed
// (database version 1). Its contents must stay byte-for-byte compatible
// with what a pre-migration install already has on disk, since existing
// installs are already at version 1 and this migration never runs again
// for them.
Future<void> _migration1CreateBaseSchema(
    sqflite_common.DatabaseExecutor db) async {
  // Persons table
  await db.execute('''
    CREATE TABLE persons (
      id TEXT PRIMARY KEY,
      data TEXT NOT NULL,
      version INTEGER DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      is_deleted INTEGER DEFAULT 0
    )
  ''');

  // Connections table
  await db.execute('''
    CREATE TABLE connections (
      id TEXT PRIMARY KEY,
      person1_id TEXT NOT NULL,
      person2_id TEXT NOT NULL,
      relationship_type TEXT NOT NULL,
      origin_event_id TEXT,
      data TEXT NOT NULL,
      version INTEGER DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      is_deleted INTEGER DEFAULT 0,
      FOREIGN KEY (person1_id) REFERENCES persons(id),
      FOREIGN KEY (person2_id) REFERENCES persons(id),
      FOREIGN KEY (origin_event_id) REFERENCES events(id)
    )
  ''');

  // Places table
  await db.execute('''
    CREATE TABLE places (
      id TEXT PRIMARY KEY,
      data TEXT NOT NULL,
      version INTEGER DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      is_deleted INTEGER DEFAULT 0
    )
  ''');

  // Events table
  await db.execute('''
    CREATE TABLE events (
      id TEXT PRIMARY KEY,
      month_key TEXT NOT NULL,
      data TEXT NOT NULL,
      version INTEGER DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      is_deleted INTEGER DEFAULT 0
    )
  ''');

  // Objects table
  await db.execute('''
    CREATE TABLE objects (
      id TEXT PRIMARY KEY,
      data TEXT NOT NULL,
      version INTEGER DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      is_deleted INTEGER DEFAULT 0
    )
  ''');

  // Files table
  await db.execute('''
    CREATE TABLE files (
      id TEXT PRIMARY KEY,
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      file_name TEXT NOT NULL,
      file_path TEXT NOT NULL,
      mime_type TEXT NOT NULL,
      size INTEGER NOT NULL,
      version INTEGER DEFAULT 0,
      created_at TEXT NOT NULL
    )
  ''');

  // Pending changes for offline sync
  await db.execute('''
    CREATE TABLE pending_changes (
      id TEXT PRIMARY KEY,
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      operation TEXT NOT NULL,
      data TEXT NOT NULL,
      created_at TEXT NOT NULL,
      synced INTEGER DEFAULT 0
    )
  ''');

  // Sync index
  await db.execute('''
    CREATE TABLE sync_index (
      id INTEGER PRIMARY KEY,
      data TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');

  // Create indexes
  await db.execute('CREATE INDEX idx_events_month ON events(month_key)');
  await db.execute(
      'CREATE INDEX idx_files_entity ON files(entity_type, entity_id)');
  await db
      .execute('CREATE INDEX idx_pending_synced ON pending_changes(synced)');
}

// ==================== Migration 2: local recordings ====================
// Tracks which audio recordings exist on THIS device and their lifecycle
// state. This is local bookkeeping only (not synced data): it lets the app
// find orphaned/unfinished recordings after a crash and know when it is
// safe to delete a recording's bytes from the RecordingFileStore.
//
// Deletion rule (see RecordingFileStore doc comment for the full policy):
// a row here is removed - and its bytes deleted from the RecordingFileStore
// - only after the user explicitly confirms deleting the recording, or
// empties a soft-deleted event that still owns it. Soft-deleting an event
// (is_deleted = 1) must NOT by itself delete the recording's bytes.
Future<void> _migration2CreateLocalRecordingsTable(
    sqflite_common.DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE local_recordings (
      id TEXT PRIMARY KEY,
      event_id TEXT,
      state TEXT NOT NULL DEFAULT 'recording',
      size INTEGER,
      sha256 TEXT,
      duration_ms INTEGER,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');
  await db.execute(
      'CREATE INDEX idx_local_recordings_event ON local_recordings(event_id)');
}
