import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart' show databaseFactorySqflitePlugin;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'package:sqflite_common/sqflite.dart' as sqflite_common;
import '../models/models.dart';
import 'database_location.dart';
import 'db_migrations.dart';
import 'recording_file_store.dart';

class DatabaseService extends ChangeNotifier {
  /// Optional overrides for tests: an explicit [DatabaseFactory] (e.g. the
  /// native FFI factory pointed at an in-memory database) and/or a custom
  /// database path. When both are left null, production code resolves a
  /// per-platform [DatabaseLocation] instead (see [_ensureFactoryAndPath]),
  /// so tests that inject a factory never touch the real filesystem or
  /// Platform checks.
  final sqflite_common.DatabaseFactory? _injectedFactory;
  final String? _injectedPath;

  /// Default database file name, used when no explicit [path] is given.
  static const String defaultFileName = 'relationship_manager.db';

  DatabaseService({
    sqflite_common.DatabaseFactory? factory,
    String? path,
  })  : _injectedFactory = factory,
        _injectedPath = path;

  sqflite_common.Database? _database;
  bool _initialized = false;
  bool _factoryInitialized = false;
  sqflite_common.DatabaseFactory? _factory;
  String? _resolvedPath;

  bool get isInitialized => _initialized;

  Future<void> _ensureFactoryAndPath() async {
    if (_factoryInitialized) return;

    if (_injectedFactory != null) {
      // Test seam: caller controls both factory and path explicitly, so
      // skip all platform/location resolution below.
      _factory = _injectedFactory;
      _resolvedPath = _injectedPath ?? defaultFileName;
    } else if (kIsWeb) {
      // Web database factory with IndexedDB backend. No real filesystem
      // path, so there is nothing to resolve via DatabaseLocation.
      _factory = databaseFactoryFfiWebNoWebWorker;
      _resolvedPath = _injectedPath ?? defaultFileName;
    } else {
      final location =
          await resolveDatabaseLocation(_injectedPath ?? defaultFileName);
      if (location.useNativePlugin) {
        // Android/iOS: the real sqflite plugin, a platform channel to the
        // OS's own SQLite - see database_location_native.dart for why.
        _factory = databaseFactorySqflitePlugin;
      } else {
        // Desktop: FFI, dlopen-ing the system libsqlite3.
        sqfliteFfiInit();
        _factory = databaseFactoryFfi;
      }
      _resolvedPath = location.path;
    }

    _factoryInitialized = true;
  }

  Future<sqflite_common.Database> get database async {
    if (_database != null) return _database!;
    await _ensureFactoryAndPath();
    _database = await _initDatabase();
    return _database!;
  }

  Future<void> initialize() async {
    if (!_initialized) {
      await _ensureFactoryAndPath();
      _database = await _initDatabase();
      _initialized = true;
      notifyListeners();
    }
  }

  Future<sqflite_common.Database> _initDatabase() async {
    return await _factory!.openDatabase(
      _resolvedPath!,
      options: sqflite_common.OpenDatabaseOptions(
        version: latestDbVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
  }

  // A fresh install starts at an empty database, so every migration runs in
  // order to build the schema up from nothing.
  Future<void> _onCreate(sqflite_common.Database db, int version) async {
    for (final migration in dbMigrations) {
      await migration.up(db);
    }
  }

  // An upgraded install already has everything up to oldVersion; only run
  // the migrations after that, in order, so it ends up with the exact same
  // schema a fresh install would get.
  Future<void> _onUpgrade(
      sqflite_common.Database db, int oldVersion, int newVersion) async {
    for (final migration in dbMigrations) {
      if (migration.version > oldVersion && migration.version <= newVersion) {
        await migration.up(db);
      }
    }
  }

  // ==================== PERSONS ====================

  Future<List<Person>> getPersons({bool includeDeleted = false}) async {
    final db = await database;
    final where = includeDeleted ? null : 'is_deleted = 0';
    final results = await db.query('persons', where: where);
    return results
        .map((row) => Person.fromJson(jsonDecode(row['data'] as String)))
        .toList();
  }

  Future<Person?> getPerson(String id) async {
    final db = await database;
    final results = await db.query('persons', where: 'id = ?', whereArgs: [id]);
    if (results.isEmpty) return null;
    return Person.fromJson(jsonDecode(results.first['data'] as String));
  }

  /// [recordPendingChange] should stay true for any locally-originated
  /// change (the normal case). The sync download path passes false: a
  /// person/place/object/connection/event just downloaded from the backend
  /// must not be queued to be uploaded straight back to it - see
  /// SyncService._downloadAndApplyBlob.
  Future<void> savePerson(Person person, {bool recordPendingChange = true}) async {
    final db = await database;
    final exists =
        (await db.query('persons', where: 'id = ?', whereArgs: [person.id]))
            .isNotEmpty;

    final data = {
      'id': person.id,
      'data': jsonEncode(person.toJson()),
      'version': person.updatedAt.millisecondsSinceEpoch,
      'created_at': person.createdAt.toIso8601String(),
      'updated_at': person.updatedAt.toIso8601String(),
      'is_deleted': person.isDeleted ? 1 : 0,
    };

    if (exists) {
      await db.update('persons', data, where: 'id = ?', whereArgs: [person.id]);
    } else {
      await db.insert('persons', data);
    }

    if (recordPendingChange) {
      await _addPendingChange(
          'person', person.id, exists ? 'update' : 'create', person.toJson());
    }
    notifyListeners();
  }

  Future<void> deletePerson(String id) async {
    final person = await getPerson(id);
    if (person != null) {
      await savePerson(person.copyWith(isDeleted: true));
    }
  }

  // ==================== CONNECTIONS ====================

  Future<List<Connection>> getConnections({bool includeDeleted = false}) async {
    final db = await database;
    final where = includeDeleted ? null : 'is_deleted = 0';
    final results = await db.query('connections', where: where);
    return results
        .map((row) => Connection.fromJson(jsonDecode(row['data'] as String)))
        .toList();
  }

  Future<Connection?> getConnection(String id) async {
    final db = await database;
    final results =
        await db.query('connections', where: 'id = ?', whereArgs: [id]);
    if (results.isEmpty) return null;
    return Connection.fromJson(jsonDecode(results.first['data'] as String));
  }

  Future<List<Connection>> getConnectionsForPerson(String personId,
      {bool includeDeleted = false}) async {
    final db = await database;
    String where;
    if (includeDeleted) {
      where = '(person1_id = ? OR person2_id = ?)';
    } else {
      where = '(person1_id = ? OR person2_id = ?) AND is_deleted = 0';
    }
    final results = await db.query(
      'connections',
      where: where,
      whereArgs: [personId, personId],
    );
    return results
        .map((row) => Connection.fromJson(jsonDecode(row['data'] as String)))
        .toList();
  }

  Future<List<Connection>> getConnectionsForEvent(String eventId) async {
    final db = await database;
    final results = await db.query(
      'connections',
      where: 'origin_event_id = ? AND is_deleted = 0',
      whereArgs: [eventId],
    );
    return results
        .map((row) => Connection.fromJson(jsonDecode(row['data'] as String)))
        .toList();
  }

  Future<void> saveConnection(Connection connection,
      {bool recordPendingChange = true}) async {
    final db = await database;
    final exists = (await db
            .query('connections', where: 'id = ?', whereArgs: [connection.id]))
        .isNotEmpty;

    final data = {
      'id': connection.id,
      'person1_id': connection.person1Id,
      'person2_id': connection.person2Id,
      'relationship_type': connection.relationshipType,
      'origin_event_id': connection.originEventId,
      'data': jsonEncode(connection.toJson()),
      'version': connection.updatedAt.millisecondsSinceEpoch,
      'created_at': connection.createdAt.toIso8601String(),
      'updated_at': connection.updatedAt.toIso8601String(),
      'is_deleted': connection.isDeleted ? 1 : 0,
    };

    if (exists) {
      await db.update('connections', data,
          where: 'id = ?', whereArgs: [connection.id]);
    } else {
      await db.insert('connections', data);
    }

    if (recordPendingChange) {
      await _addPendingChange('connection', connection.id,
          exists ? 'update' : 'create', connection.toJson());
    }
    notifyListeners();
  }

  Future<void> deleteConnection(String id) async {
    final connection = await getConnection(id);
    if (connection != null) {
      await saveConnection(connection.copyWith(isDeleted: true));
    }
  }

  // ==================== PLACES ====================

  Future<List<Place>> getPlaces({bool includeDeleted = false}) async {
    final db = await database;
    final where = includeDeleted ? null : 'is_deleted = 0';
    final results = await db.query('places', where: where);
    return results
        .map((row) => Place.fromJson(jsonDecode(row['data'] as String)))
        .toList();
  }

  Future<Place?> getPlace(String id) async {
    final db = await database;
    final results = await db.query('places', where: 'id = ?', whereArgs: [id]);
    if (results.isEmpty) return null;
    return Place.fromJson(jsonDecode(results.first['data'] as String));
  }

  Future<void> savePlace(Place place, {bool recordPendingChange = true}) async {
    final db = await database;
    final exists =
        (await db.query('places', where: 'id = ?', whereArgs: [place.id]))
            .isNotEmpty;

    final data = {
      'id': place.id,
      'data': jsonEncode(place.toJson()),
      'version': place.updatedAt.millisecondsSinceEpoch,
      'created_at': place.createdAt.toIso8601String(),
      'updated_at': place.updatedAt.toIso8601String(),
      'is_deleted': place.isDeleted ? 1 : 0,
    };

    if (exists) {
      await db.update('places', data, where: 'id = ?', whereArgs: [place.id]);
    } else {
      await db.insert('places', data);
    }

    if (recordPendingChange) {
      await _addPendingChange(
          'place', place.id, exists ? 'update' : 'create', place.toJson());
    }
    notifyListeners();
  }

  Future<void> deletePlace(String id) async {
    final place = await getPlace(id);
    if (place != null) {
      await savePlace(place.copyWith(isDeleted: true));
    }
  }

  // ==================== EVENTS ====================

  Future<List<Event>> getEvents(
      {String? monthKey, bool includeDeleted = false}) async {
    final db = await database;
    String? where;
    List<dynamic>? whereArgs;

    if (monthKey != null && !includeDeleted) {
      where = 'month_key = ? AND is_deleted = 0';
      whereArgs = [monthKey];
    } else if (monthKey != null) {
      where = 'month_key = ?';
      whereArgs = [monthKey];
    } else if (!includeDeleted) {
      where = 'is_deleted = 0';
    }

    final results =
        await db.query('events', where: where, whereArgs: whereArgs);
    return results
        .map((row) => Event.fromJson(jsonDecode(row['data'] as String)))
        .toList();
  }

  Future<Event?> getEvent(String id) async {
    final db = await database;
    final results = await db.query('events', where: 'id = ?', whereArgs: [id]);
    if (results.isEmpty) return null;
    return Event.fromJson(jsonDecode(results.first['data'] as String));
  }

  Future<void> saveEvent(Event event, {bool recordPendingChange = true}) async {
    final db = await database;
    final exists =
        (await db.query('events', where: 'id = ?', whereArgs: [event.id]))
            .isNotEmpty;

    final data = {
      'id': event.id,
      'month_key': event.monthKey,
      'data': jsonEncode(event.toJson()),
      'version': event.updatedAt.millisecondsSinceEpoch,
      'created_at': event.createdAt.toIso8601String(),
      'updated_at': event.updatedAt.toIso8601String(),
      'is_deleted': event.isDeleted ? 1 : 0,
    };

    if (exists) {
      await db.update('events', data, where: 'id = ?', whereArgs: [event.id]);
    } else {
      await db.insert('events', data);
    }

    if (recordPendingChange) {
      await _addPendingChange(
          'event', event.id, exists ? 'update' : 'create', event.toJson());
    }
    notifyListeners();
  }

  Future<void> deleteEvent(String id) async {
    final event = await getEvent(id);
    if (event != null) {
      await saveEvent(event.copyWith(isDeleted: true));
    }
  }

  // ==================== OBJECTS ====================

  Future<List<EventObject>> getObjects({bool includeDeleted = false}) async {
    final db = await database;
    final where = includeDeleted ? null : 'is_deleted = 0';
    final results = await db.query('objects', where: where);
    return results
        .map((row) => EventObject.fromJson(jsonDecode(row['data'] as String)))
        .toList();
  }

  Future<EventObject?> getObject(String id) async {
    final db = await database;
    final results = await db.query('objects', where: 'id = ?', whereArgs: [id]);
    if (results.isEmpty) return null;
    return EventObject.fromJson(jsonDecode(results.first['data'] as String));
  }

  Future<void> saveObject(EventObject object, {bool recordPendingChange = true}) async {
    final db = await database;
    final exists =
        (await db.query('objects', where: 'id = ?', whereArgs: [object.id]))
            .isNotEmpty;

    final data = {
      'id': object.id,
      'data': jsonEncode(object.toJson()),
      'version': object.updatedAt.millisecondsSinceEpoch,
      'created_at': object.createdAt.toIso8601String(),
      'updated_at': object.updatedAt.toIso8601String(),
      'is_deleted': object.isDeleted ? 1 : 0,
    };

    if (exists) {
      await db.update('objects', data, where: 'id = ?', whereArgs: [object.id]);
    } else {
      await db.insert('objects', data);
    }

    if (recordPendingChange) {
      await _addPendingChange(
          'object', object.id, exists ? 'update' : 'create', object.toJson());
    }
    notifyListeners();
  }

  Future<void> deleteObject(String id) async {
    final object = await getObject(id);
    if (object != null) {
      await saveObject(object.copyWith(isDeleted: true));
    }
  }

  // ==================== PENDING CHANGES ====================

  Future<void> _addPendingChange(String entityType, String entityId,
      String operation, Map<String, dynamic> data) async {
    final db = await database;
    final id =
        '${entityType}_${entityId}_${DateTime.now().millisecondsSinceEpoch}';

    await db.insert('pending_changes', {
      'id': id,
      'entity_type': entityType,
      'entity_id': entityId,
      'operation': operation,
      'data': jsonEncode(data),
      'created_at': DateTime.now().toIso8601String(),
      'synced': 0,
    });
  }

  Future<List<PendingChange>> getPendingChanges() async {
    final db = await database;
    final results = await db.query('pending_changes',
        where: 'synced = 0', orderBy: 'created_at ASC');
    return results
        .map((row) => PendingChange(
              id: row['id'] as String,
              entityType: row['entity_type'] as String,
              entityId: row['entity_id'] as String,
              operation: row['operation'] as String,
              data: jsonDecode(row['data'] as String),
              createdAt: DateTime.parse(row['created_at'] as String),
              synced: (row['synced'] as int) == 1,
            ))
        .toList();
  }

  Future<void> markChangesSynced(List<String> ids) async {
    final db = await database;
    for (final id in ids) {
      await db.update('pending_changes', {'synced': 1},
          where: 'id = ?', whereArgs: [id]);
    }
  }

  Future<void> clearSyncedChanges() async {
    final db = await database;
    await db.delete('pending_changes', where: 'synced = 1');
  }

  // ==================== SYNC INDEX ====================

  Future<SyncIndex?> getSyncIndex() async {
    final db = await database;
    final results = await db.query('sync_index', where: 'id = 1');
    if (results.isEmpty) return null;
    return SyncIndex.fromJson(jsonDecode(results.first['data'] as String));
  }

  Future<void> saveSyncIndex(SyncIndex index) async {
    final db = await database;
    final exists = (await db.query('sync_index', where: 'id = 1')).isNotEmpty;

    final data = {
      'id': 1,
      'data': jsonEncode(index.toJson()),
      'updated_at': DateTime.now().toIso8601String(),
    };

    if (exists) {
      await db.update('sync_index', data, where: 'id = 1');
    } else {
      await db.insert('sync_index', data);
    }
  }

  // ==================== LOCAL RECORDINGS ====================
  // Local-only bookkeeping about recordings' bytes on this device. Not part
  // of the synced Event/AttachedFile data - see LocalRecordingState's doc
  // comment for what each row means and the deletion rule.

  Future<void> saveLocalRecording(LocalRecordingState recording) async {
    final db = await database;
    await db.insert(
      'local_recordings',
      recording.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<LocalRecordingState?> getLocalRecording(String id) async {
    final db = await database;
    final results =
        await db.query('local_recordings', where: 'id = ?', whereArgs: [id]);
    if (results.isEmpty) return null;
    return LocalRecordingState.fromRow(results.first);
  }

  Future<List<LocalRecordingState>> getLocalRecordingsByState(
      RecordingLifecycleState state) async {
    final db = await database;
    final results = await db.query('local_recordings',
        where: 'state = ?', whereArgs: [state.name]);
    return results.map(LocalRecordingState.fromRow).toList();
  }

  Future<List<LocalRecordingState>> getLocalRecordingsForEvent(
      String eventId) async {
    final db = await database;
    final results = await db.query('local_recordings',
        where: 'event_id = ?', whereArgs: [eventId]);
    return results.map(LocalRecordingState.fromRow).toList();
  }

  /// Recordings that exist on this device but aren't attached to any
  /// story: finished captures whose eventId was never set, either because
  /// the quick-add sheet that started them was dismissed before Save, or
  /// because RecordingRecoveryService found them abandoned at start-up
  /// after a crash. Excludes rows still mid-recording (state ==
  /// [RecordingLifecycleState.recording]) - those aren't abandoned, they're
  /// just in progress. Surfaced by the map's "N recordings aren't attached
  /// to a story" banner.
  Future<List<LocalRecordingState>> getOrphanedRecordings() async {
    final db = await database;
    final results = await db.query(
      'local_recordings',
      where: 'event_id IS NULL AND state != ?',
      whereArgs: [RecordingLifecycleState.recording.name],
    );
    return results.map(LocalRecordingState.fromRow).toList();
  }

  /// Removes just the bookkeeping row, without touching any bytes in a
  /// RecordingFileStore. Used when a recording never produced any bytes
  /// worth keeping (e.g. recovery found an empty orphaned entry). For an
  /// actual recording, use [deleteRecordingPermanently] instead so its
  /// bytes are deleted too.
  Future<void> deleteLocalRecordingRow(String id) async {
    final db = await database;
    await db.delete('local_recordings', where: 'id = ?', whereArgs: [id]);
  }

  /// Permanently deletes a recording: its bytes in [store] AND its local
  /// bookkeeping row.
  ///
  /// IMPORTANT deletion rule: call this only after the user has explicitly
  /// confirmed deleting that specific recording (e.g. a "Delete recording"
  /// confirmation dialog), or when emptying a soft-deleted event that still
  /// owns it. Soft-deleting an event (`Event.isDeleted = true` /
  /// [deleteEvent]) must NEVER by itself reach this method - the audio has
  /// to stay recoverable for as long as the soft-deleted event could still
  /// be restored.
  Future<void> deleteRecordingPermanently(
      String recordingId, RecordingFileStore store) async {
    await store.delete(recordingId);
    await deleteLocalRecordingRow(recordingId);
  }

  // ==================== BULK OPERATIONS ====================

  Future<void> bulkSavePersons(List<Person> persons) async {
    final db = await database;
    final batch = db.batch();

    for (final person in persons) {
      batch.insert(
        'persons',
        {
          'id': person.id,
          'data': jsonEncode(person.toJson()),
          'version': person.updatedAt.millisecondsSinceEpoch,
          'created_at': person.createdAt.toIso8601String(),
          'updated_at': person.updatedAt.toIso8601String(),
          'is_deleted': person.isDeleted ? 1 : 0,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    await batch.commit(noResult: true);
    notifyListeners();
  }

  Future<void> bulkSaveEvents(List<Event> events) async {
    final db = await database;
    final batch = db.batch();

    for (final event in events) {
      batch.insert(
        'events',
        {
          'id': event.id,
          'month_key': event.monthKey,
          'data': jsonEncode(event.toJson()),
          'version': event.updatedAt.millisecondsSinceEpoch,
          'created_at': event.createdAt.toIso8601String(),
          'updated_at': event.updatedAt.toIso8601String(),
          'is_deleted': event.isDeleted ? 1 : 0,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    await batch.commit(noResult: true);
    notifyListeners();
  }

  // Clear all data (for logout)
  Future<void> clearAllData() async {
    final db = await database;
    await db.delete('persons');
    await db.delete('connections');
    await db.delete('places');
    await db.delete('events');
    await db.delete('objects');
    await db.delete('files');
    await db.delete('pending_changes');
    await db.delete('sync_index');
    // Bookkeeping rows only; actual recording bytes in a RecordingFileStore
    // are intentionally left alone here - see deleteRecordingPermanently's
    // doc comment for why this must never be an implicit side effect.
    await db.delete('local_recordings');
    notifyListeners();
  }

  // ==================== BACKUP/RESTORE ====================
  // notifyListeners() is @protected, so code outside this class (the
  // backup/restore feature under lib/backup/, which writes entity rows
  // directly via the `database` getter rather than duplicating each
  // save*() method) needs a public way to ask listening widgets to
  // refresh after a restore changes data underneath them.

  void notifyDataRestored() => notifyListeners();
}
