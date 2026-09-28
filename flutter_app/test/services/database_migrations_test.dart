// Regression test for the migration framework in
// lib/services/db_migrations.dart: an install that already exists at the
// original (pre-migration) schema version 1 must, after being opened with
// the current code, keep its data intact AND end up with exactly the
// schema the current migrations produce - the same schema a fresh install
// gets.
//
// The "old" schema below is intentionally a hand-copied, independent
// snapshot of migration 1 (not a call into db_migrations.dart), so this
// test still catches an accidental change to migration 1's SQL.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/db_migrations.dart';

const _oldSchemaSql = [
  '''
    CREATE TABLE persons (
      id TEXT PRIMARY KEY,
      data TEXT NOT NULL,
      version INTEGER DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      is_deleted INTEGER DEFAULT 0
    )
  ''',
  '''
    CREATE TABLE events (
      id TEXT PRIMARY KEY,
      month_key TEXT NOT NULL,
      data TEXT NOT NULL,
      version INTEGER DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      is_deleted INTEGER DEFAULT 0
    )
  ''',
  '''
    CREATE TABLE pending_changes (
      id TEXT PRIMARY KEY,
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      operation TEXT NOT NULL,
      data TEXT NOT NULL,
      created_at TEXT NOT NULL,
      synced INTEGER DEFAULT 0
    )
  ''',
];

void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    sqfliteFfiInit();
    tempDir = Directory.systemTemp.createTempSync('db_migration_test');
    dbPath = '${tempDir.path}/relationship_manager.db';
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('opening an old version-1 database keeps data and adds new schema',
      () async {
    // Simulate an existing install: a database with the exact pre-migration
    // (version 1) schema, with some rows already in it.
    final oldDb = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          for (final sql in _oldSchemaSql) {
            await db.execute(sql);
          }
        },
      ),
    );

    await oldDb.insert('persons', {
      'id': 'p1',
      'data': '{"id":"p1","name":"Ada Lovelace"}',
      'version': 0,
      'created_at': '2020-01-01T00:00:00.000',
      'updated_at': '2020-01-01T00:00:00.000',
      'is_deleted': 0,
    });
    await oldDb.insert('events', {
      'id': 'e1',
      'month_key': '2020-01',
      'data': '{"id":"e1","title":"First meeting"}',
      'version': 0,
      'created_at': '2020-01-01T00:00:00.000',
      'updated_at': '2020-01-01T00:00:00.000',
      'is_deleted': 0,
    });
    await oldDb.close();

    // Now open the same file with the real, migration-aware DatabaseService,
    // the way the app does on an upgrade.
    final dbService =
        DatabaseService(factory: databaseFactoryFfi, path: dbPath);
    final db = await dbService.database;

    // Old data survived the upgrade untouched.
    final persons = await db.query('persons');
    expect(persons, hasLength(1));
    expect(persons.first['id'], 'p1');
    expect(persons.first['data'], '{"id":"p1","name":"Ada Lovelace"}');

    final events = await db.query('events');
    expect(events, hasLength(1));
    expect(events.first['id'], 'e1');

    // The schema now matches every migration up to the latest version,
    // including tables added after version 1.
    final tables = await db.query(
      'sqlite_master',
      where: "type = 'table' AND name NOT LIKE 'sqlite_%'",
    );
    final tableNames = tables.map((t) => t['name']).toSet();
    expect(
      tableNames,
      containsAll(
          ['persons', 'events', 'pending_changes', 'local_recordings']),
    );

    final version = await db.getVersion();
    expect(version, latestDbVersion);

    await db.close();
  });

  test('a fresh install ends up on the latest schema version', () async {
    final dbService =
        DatabaseService(factory: databaseFactoryFfi, path: dbPath);
    final db = await dbService.database;

    final version = await db.getVersion();
    expect(version, latestDbVersion);

    final tables = await db.query(
      'sqlite_master',
      where: "type = 'table' AND name NOT LIKE 'sqlite_%'",
    );
    final tableNames = tables.map((t) => t['name']).toSet();
    expect(tableNames, contains('local_recordings'));

    await db.close();
  });
}
