import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/services/auth_service.dart';
import 'package:relationship_manager/services/encryption_service.dart';
import 'package:relationship_manager/services/sync_service.dart';

import '../support/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({
        'auth_token': 'fake.token.value',
        'user_id': 'u1',
      }));

  for (final failedType in [
    'person',
    'place',
    'object',
    'connection',
    'event_month',
    'index'
  ]) {
    test('failed $failedType commit retains pending changes for retry',
        () async {
      final db = createTestDatabaseService();
      await db.initialize();
      await db.savePerson(Person(id: 'p1', name: 'Anna'));
      await db
          .savePlace(Place(name: 'Berlin', latitude: 52.5, longitude: 13.4));
      await db.saveObject(EventObject(name: 'Photo'));
      await db.saveConnection(Connection(
          person1Id: 'p1', person2Id: 'p2', relationshipType: 'sibling'));
      await db.saveEvent(Event(title: 'Story', dateTime: DateTime(1952)));
      final pendingIds =
          (await db.getPendingChanges()).map((c) => c.id).toSet();
      var fail = true;
      final auth = AuthService(httpClient: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (request.url.path == '/api/sync/upload') {
          return http.Response(
              jsonEncode(
                  {'uploadUrl': 'https://storage.test/blob', 's3Key': 'key'}),
              200);
        }
        return http.Response(
            '{}', fail && body['blobType'] == failedType ? 503 : 200);
      }));
      await auth.initialize();
      final sync = SyncService(db, auth,
          httpClient: MockClient((_) async => http.Response('', 200)))
        ..initializeEncryption('password');
      await sync.syncOnClose();
      expect(sync.lastError, contains('503'));
      final remaining = await db.getPendingChanges();
      // An index failure must retain the whole batch; entity failures retain
      // their own changes while successfully committed entities can clear.
      expect(remaining, isNotEmpty);
      expect(pendingIds, containsAll(remaining.map((c) => c.id)));
      if (failedType != 'index') {
        expect(
            remaining.every((c) =>
                c.entityType ==
                (failedType == 'event_month' ? 'event' : failedType)),
            isTrue);
      }
      fail = false;
      await sync.syncOnClose();
      expect(await db.getPendingChanges(), isEmpty);
      expect(sync.lastError, isNull);
    });
  }

  for (final failure in ['updates', 'download', 'blob', 'decrypt']) {
    test('$failure failure preserves download cursor and retries successfully',
        () async {
      final db = createTestDatabaseService();
      await db.initialize();
      await db.saveSyncIndex(SyncIndex(lastSyncTimestamp: 8));
      final person = Person(id: 'remote', name: 'Bert');
      final encryptor = EncryptionService()
        ..initializeWithPassword('password', 'u1');
      var fail = true;
      final requestedVersions = <int>[];
      final auth = AuthService(httpClient: MockClient((request) async {
        if (request.url.path == '/api/sync/updates') {
          requestedVersions
              .add(jsonDecode(request.body)['lastSyncVersion'] as int);
          return http.Response(
              jsonEncode({
                'entries': [
                  {
                    'blobType': 'person',
                    'blobId': person.id,
                    's3Key': 'key',
                    'version': 9
                  }
                ],
                'latestVersion': 9
              }),
              fail && failure == 'updates' ? 503 : 200);
        }
        return http.Response(
            jsonEncode({'downloadUrl': 'https://storage.test/blob'}),
            fail && failure == 'download' ? 503 : 200);
      }));
      await auth.initialize();
      final sync = SyncService(db, auth,
          httpClient: MockClient((_) async => http.Response(
                fail && failure == 'decrypt'
                    ? 'invalid ciphertext'
                    : encryptor.encryptString(jsonEncode(person.toJson())),
                fail && failure == 'blob' ? 503 : 200,
              )))
        ..initializeEncryption('password');
      await sync.syncOnOpen();
      expect((await db.getSyncIndex())!.lastSyncTimestamp, 8);
      expect(sync.lastError, isNotNull);
      expect(sync.lastSyncTime, isNull);
      fail = false;
      await sync.syncOnOpen();
      expect(requestedVersions, [8, 8]);
      expect((await db.getSyncIndex())!.lastSyncTimestamp, 9);
      expect((await db.getPerson(person.id))!.name, 'Bert');
      expect(await db.getPendingChanges(), isEmpty);
      expect(sync.lastError, isNull);
    });
  }

  test('remote index does not advance cursor before a later failed download',
      () async {
    final db = createTestDatabaseService();
    await db.initialize();
    await db.saveSyncIndex(SyncIndex(lastSyncTimestamp: 8));
    final encryptor = EncryptionService()
      ..initializeWithPassword('password', 'u1');
    final auth = AuthService(httpClient: MockClient((request) async {
      if (request.url.path == '/api/sync/updates') {
        return http.Response(
            jsonEncode({
              'entries': [
                {
                  'blobType': 'index',
                  'blobId': 'main',
                  's3Key': 'key',
                  'version': 9
                },
                {
                  'blobType': 'person',
                  'blobId': 'missing',
                  's3Key': 'key',
                  'version': 10
                },
              ],
              'latestVersion': 10
            }),
            200);
      }
      return http.Response(
          jsonEncode({'downloadUrl': 'https://storage.test/index'}),
          request.url.path.endsWith('/main') ? 200 : 503);
    }));
    await auth.initialize();
    final sync = SyncService(db, auth,
        httpClient: MockClient((_) async => http.Response(
            encryptor.encryptString(
                jsonEncode(SyncIndex(lastSyncTimestamp: 999).toJson())),
            200)))
      ..initializeEncryption('password');
    await sync.syncOnOpen();
    expect((await db.getSyncIndex())!.lastSyncTimestamp, 8);
    expect(sync.lastError, contains('503'));
  });

  test('full sync does not upload pending changes after a failed download',
      () async {
    final db = createTestDatabaseService();
    await db.initialize();
    await db.savePerson(Person(name: 'Local edit'));
    final auth = AuthService(httpClient: MockClient((request) async {
      expect(request.url.path, '/api/sync/updates');
      return http.Response('{}', 503);
    }));
    await auth.initialize();
    final sync = SyncService(db, auth)..initializeEncryption('password');
    await sync.forceFullSync();
    expect(await db.getPendingChanges(), hasLength(1));
    expect(sync.lastError, contains('503'));
    expect(sync.lastSyncTime, isNull);
  });

  test(
      'remote tombstones delete local entities without downloads or requeueing',
      () async {
    final db = createTestDatabaseService();
    await db.initialize();
    final person = Person(id: 'p1', name: 'Anna');
    final place = Place(name: 'Berlin', latitude: 52.5, longitude: 13.4);
    final object = EventObject(name: 'Photo');
    final connection = Connection(
        person1Id: person.id, person2Id: 'p2', relationshipType: 'sibling');
    final event = Event(title: 'Story', dateTime: DateTime(1952));
    await db.savePerson(person, recordPendingChange: false);
    await db.savePlace(place, recordPendingChange: false);
    await db.saveObject(object, recordPendingChange: false);
    await db.saveConnection(connection, recordPendingChange: false);
    await db.saveEvent(event, recordPendingChange: false);
    final ids = {
      'person': person.id,
      'place': place.id,
      'object': object.id,
      'connection': connection.id,
      'event_month': event.monthKey
    };
    final auth = AuthService(httpClient: MockClient((request) async {
      expect(request.url.path, '/api/sync/updates');
      return http.Response(
          jsonEncode({
            'entries': ids.entries
                .map((e) => {
                      'blobType': e.key,
                      'blobId': e.value,
                      's3Key': 'key',
                      'version': 9,
                      'isDeleted': true
                    })
                .toList(),
            'latestVersion': 9
          }),
          200);
    }));
    await auth.initialize();
    final sync = SyncService(db, auth,
        httpClient: MockClient(
            (_) async => throw StateError('Tombstones need no blob')))
      ..initializeEncryption('password');
    await sync.syncOnOpen();
    expect(await db.getPersons(), isEmpty);
    expect(await db.getPlaces(), isEmpty);
    expect(await db.getObjects(), isEmpty);
    expect(await db.getConnections(), isEmpty);
    expect(await db.getEvents(), isEmpty);
    expect((await db.getConnection(connection.id))!.isDeleted, isTrue);
    expect(await db.getPendingChanges(), isEmpty);
    expect((await db.getSyncIndex())!.lastSyncTimestamp, 9);
    expect(sync.lastError, isNull);
  });
}
