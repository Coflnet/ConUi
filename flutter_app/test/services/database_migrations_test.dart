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
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/db_migrations.dart';

const _oldSchemaSql = [
  '''
    CREATE TABLE files (
      id TEXT PRIMARY KEY, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
      file_name TEXT NOT NULL, file_path TEXT NOT NULL, mime_type TEXT NOT NULL,
      size INTEGER NOT NULL, version INTEGER DEFAULT 0, created_at TEXT NOT NULL
    )
  ''',
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
      containsAll(['persons', 'events', 'pending_changes', 'local_recordings', 'recording_segments']),
    );

    final version = await db.getVersion();
    expect(version, latestDbVersion);

    await db.close();
  });

  test(
      'upgrade from version 2 preserves files and stories and enables photo bytes',
      () async {
    final oldDb = await databaseFactoryFfi.openDatabase(dbPath,
        options: OpenDatabaseOptions(
            version: 2,
            onCreate: (db, _) async {
              for (final migration in dbMigrations
                  .where((migration) => migration.version <= 2)) {
                await migration.up(db);
              }
            }));
    await oldDb.insert('files', {
      'id': 'photo',
      'entity_type': 'event',
      'entity_id': 'story',
      'file_name': 'family.png',
      'file_path': 'legacy/path',
      'mime_type': 'image/png',
      'size': 3,
      'created_at': '1952-01-01',
    });
    await oldDb.insert('events', {
      'id': 'story',
      'month_key': '1952-01',
      'data': '{"title":"Family"}',
      'created_at': '1952-01-01',
      'updated_at': '1952-01-01',
    });
    await oldDb.close();
    final service = DatabaseService(factory: databaseFactoryFfi, path: dbPath);
    final upgraded = await service.database;
    expect((await upgraded.query('files')).single['file_path'], 'legacy/path');
    expect(
        (await upgraded.query('events')).single['data'], '{"title":"Family"}');
    await upgraded.update('files', {
      'bytes': Uint8List.fromList([1, 2, 3])
    });
    expect((await upgraded.query('files')).single['bytes'], [1, 2, 3]);
    expect(await upgraded.getVersion(), latestDbVersion);
    await upgraded.close();
  });

  test('version 4 boundaries survive upgrade and speech decisions resolve once', () async {
    final oldDb = await databaseFactoryFfi.openDatabase(dbPath,
        options: OpenDatabaseOptions(version: 4, onCreate: (db, _) async {
          for (final migration in dbMigrations.where((m) => m.version <= 4)) {
            await migration.up(db);
          }
        }));
    await oldDb.insert('recording_segments', {
      'recording_id': 'saved', 'sequence': 0, 'byte_length': 192000,
    });
    await oldDb.close();

    final service = DatabaseService(factory: databaseFactoryFfi, path: dbPath);
    expect(await service.getRecordingSegments('saved'),
        [(length: 192000, hasSpeech: null, text: null)]);
    // A changed boundary must not overwrite the recorded identity or classify it.
    await service.saveRecordingSegment('saved', 0, 96000, hasSpeech: true);
    expect((await service.getRecordingSegments('saved')).single.hasSpeech, isNull);
    await service.saveRecordingSegment('saved', 0, 192000, hasSpeech: false);
    await service.saveRecordingSegment('saved', 0, 192000, hasSpeech: true);
    await service.saveRecordingSegment('saved', 1, 32000, hasSpeech: true);
    expect(await service.getRecordingSegments('saved'), [
      (length: 192000, hasSpeech: false, text: null), (length: 32000, hasSpeech: true, text: null),
    ]);
    await (await service.database).close();
  });

  test('version 5 preserves boundaries and stores original text exactly once', () async {
    final oldDb = await databaseFactoryFfi.openDatabase(dbPath,
        options: OpenDatabaseOptions(version: 5, onCreate: (db, _) async {
          for (final migration in dbMigrations.where((m) => m.version <= 5)) {
            await migration.up(db);
          }
        }));
    for (var sequence = 0; sequence < 2; sequence++) {
      await oldDb.insert('recording_segments', {
        'recording_id': 'original', 'sequence': sequence,
        'byte_length': 32000, 'has_speech': sequence,
      });
    }
    await oldDb.insert('recording_segments', {
      'recording_id': 'known-silence', 'sequence': 0,
      'byte_length': 32000, 'has_speech': 0,
    });
    await oldDb.close();
    final service = DatabaseService(factory: databaseFactoryFfi, path: dbPath);
    final silence = (await service.getRecordingTranscriptSlices('known-silence'))!.single;
    expect(silence.text, '');
    expect(silence.startByte, 0);
    expect(silence.endByte, 32000);
    expect(await service.getRecordingTranscriptSlices('missing'), isNull);
    expect((await service.getRecordingSegments('original')).map((s) => s.text), [null, null]);
    expect((await service.getRecordingTranscriptSlices('original'))!.single.text, '');
    await service.saveRecordingSegmentText('original', 0, 32000, '');
    expect((await service.getRecordingTranscriptSlices('original'))!.single.text, '');
    await service.saveRecordingSegmentText('original', 1, 16000, 'Wrong boundary');
    expect((await service.getRecordingSegments('original')).last.text, isNull);
    await service.saveRecordingSegmentText('original', 1, 32000, 'Original sentence.');
    await service.saveRecordingSegmentText('original', 1, 32000, 'Replacement must not overwrite.');
    final restored = (await service.getRecordingTranscriptSlices('original'))!.last;
    expect(restored.startByte, 32000);
    expect(restored.endByte, 64000);
    expect(restored.text, 'Original sentence.');
    expect((await service.getRecordingSegments('original')).first.text, '');
    await (await service.database).close();
    final reopened = DatabaseService(factory: databaseFactoryFfi, path: dbPath);
    expect((await reopened.getRecordingTranscriptSlices('original'))!.last.text, 'Original sentence.');
    await (await reopened.database).close();
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
