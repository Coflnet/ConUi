import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'package:sqflite_common/sqflite.dart' as sqflite_common;
import '../models/models.dart';

class DatabaseService extends ChangeNotifier {
  static sqflite_common.Database? _database;
  bool _initialized = false;
  static bool _factoryInitialized = false;
  static sqflite_common.DatabaseFactory? _factory;

  bool get isInitialized => _initialized;

  static Future<void> _initFactory() async {
    if (!_factoryInitialized) {
      if (kIsWeb) {
        // Initialize web database factory with IndexedDB backend
        _factory = databaseFactoryFfiWebNoWebWorker;
      } else {
        // Initialize FFI database factory for desktop
        sqfliteFfiInit();
        _factory = databaseFactoryFfi;
      }
      _factoryInitialized = true;
    }
  }

  Future<sqflite_common.Database> get database async {
    if (_database != null) return _database!;
    await _initFactory();
    _database = await _initDatabase();
    return _database!;
  }

  Future<void> initialize() async {
    if (!_initialized) {
      await _initFactory();
      _database = await _initDatabase();
      _initialized = true;
      notifyListeners();
    }
  }

  Future<sqflite_common.Database> _initDatabase() async {
    String path = 'relationship_manager.db';

    return await _factory!.openDatabase(
      path,
      options: sqflite_common.OpenDatabaseOptions(
        version: 1,
        onCreate: _onCreate,
      ),
    );
  }

  Future<void> _onCreate(sqflite_common.Database db, int version) async {
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

  Future<void> savePerson(Person person) async {
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

    await _addPendingChange(
        'person', person.id, exists ? 'update' : 'create', person.toJson());
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

  Future<void> saveConnection(Connection connection) async {
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
      'is_deleted': 0,
    };

    if (exists) {
      await db.update('connections', data,
          where: 'id = ?', whereArgs: [connection.id]);
    } else {
      await db.insert('connections', data);
    }

    await _addPendingChange('connection', connection.id,
        exists ? 'update' : 'create', connection.toJson());
    notifyListeners();
  }

  Future<void> deleteConnection(String id) async {
    final db = await database;
    final connection = await getConnection(id);
    if (connection != null) {
      await db.update(
          'connections',
          {
            'is_deleted': 1,
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [id]);
      await _addPendingChange('connection', id, 'delete', connection.toJson());
      notifyListeners();
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

  Future<void> savePlace(Place place) async {
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

    await _addPendingChange(
        'place', place.id, exists ? 'update' : 'create', place.toJson());
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

  Future<void> saveEvent(Event event) async {
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

    await _addPendingChange(
        'event', event.id, exists ? 'update' : 'create', event.toJson());
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

  Future<void> saveObject(EventObject object) async {
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

    await _addPendingChange(
        'object', object.id, exists ? 'update' : 'create', object.toJson());
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
    notifyListeners();
  }
}
