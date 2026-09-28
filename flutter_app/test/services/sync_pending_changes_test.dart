// Regression tests for two sync defects found during reconnaissance:
//
// 1. Deleting a connection never reached other devices. Connection had no
//    isDeleted field at all; DatabaseService.saveConnection hard-coded
//    'is_deleted': 0 into the SQL row; deleteConnection only flipped the
//    SQL column (never the stored JSON document, which is what actually
//    gets uploaded); and SyncService._uploadConnectionBlob hard-coded
//    'isDeleted': false into the commit payload regardless of the real
//    state. A synced device downloading that connection would never learn
//    it was deleted.
//
// 2. Every entity downloaded during sync (savePerson/savePlace/saveObject/
//    saveConnection/saveEvent, called from
//    SyncService._downloadAndApplyBlob) recorded a pending change exactly
//    like a local edit would, so the very next syncOnClose() uploaded that
//    same data straight back to the server it just came from.
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
  // SyncService defers notifyListeners() through SchedulerBinding, which
  // needs a Flutter binding even in a plain, non-widget test.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Connection soft-delete', () {
    test(
        'deleting a connection marks isDeleted in the stored JSON, not just the SQL column',
        () async {
      final db = createTestDatabaseService();
      await db.initialize();

      final person1 = Person(name: 'Ada Lovelace');
      final person2 = Person(name: 'Charles Babbage');
      await db.savePerson(person1);
      await db.savePerson(person2);

      final connection = Connection(
        person1Id: person1.id,
        person2Id: person2.id,
        relationshipType: 'colleague',
      );
      await db.saveConnection(connection);

      await db.deleteConnection(connection.id);

      // The JSON document itself must record the deletion - that's what's
      // actually serialized and uploaded - not just the SQL is_deleted
      // column used for local filtering.
      final stored = await db.getConnection(connection.id);
      expect(stored, isNotNull);
      expect(stored!.isDeleted, isTrue);

      expect(await db.getConnections(), isEmpty);
      expect((await db.getConnections(includeDeleted: true)).single.isDeleted,
          isTrue);

      // Soft-deleting goes through saveConnection just like Person/Place/
      // Event do, so the resulting pending change is an 'update' (the
      // connection already existed) - the deletion itself is carried by
      // isDeleted: true in the change's data, not by a distinct 'delete'
      // operation. What matters here is that the data reflects it at all.
      final pending = await db.getPendingChanges();
      final connectionChanges =
          pending.where((c) => c.entityType == 'connection').toList();
      expect(connectionChanges, isNotEmpty);
      expect(connectionChanges.last.data['isDeleted'], isTrue,
          reason: 'the pending change (what gets serialized to the blob '
              'that other devices download) must carry the deletion');
    });

    test('new JSON round-trips isDeleted, and old JSON without it defaults to false',
        () {
      final deleted = Connection(
        person1Id: 'p1',
        person2Id: 'p2',
        relationshipType: 'friend',
        isDeleted: true,
      );
      expect(Connection.fromJson(deleted.toJson()).isDeleted, isTrue);

      final oldJson = {
        'id': 'c1',
        'person1Id': 'p1',
        'person2Id': 'p2',
        'relationshipType': 'friend',
        'originEventId': null,
        'description': null,
        'startDate': '2020-01-01T00:00:00.000',
        'endDate': null,
        'createdAt': '2020-01-01T00:00:00.000',
        'updatedAt': '2020-01-01T00:00:00.000',
        // no 'isDeleted' key - a document written before this field existed.
      };
      expect(Connection.fromJson(oldJson).isDeleted, isFalse);
    });

    test('a deleted connection uploads with isDeleted true, not a hard-coded false',
        () async {
      SharedPreferences.setMockInitialValues({
        'auth_token': 'fake.token.value',
        'user_id': 'u1',
      });

      final db = createTestDatabaseService();
      await db.initialize();

      final person1 = Person(name: 'Ada Lovelace');
      final person2 = Person(name: 'Charles Babbage');
      await db.savePerson(person1);
      await db.savePerson(person2);
      final connection = Connection(
        person1Id: person1.id,
        person2Id: person2.id,
        relationshipType: 'colleague',
      );
      await db.saveConnection(connection);
      await db.deleteConnection(connection.id);

      Map<String, dynamic>? commitBody;
      final auth = AuthService(
        httpClient: MockClient((request) async {
          if (request.url.path == '/api/sync/upload') {
            return http.Response(
                jsonEncode({
                  'uploadUrl': 'https://s3.example.com/put-url',
                  's3Key': 'key123',
                }),
                200);
          }
          if (request.url.path == '/api/sync/commit') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            if (body['blobType'] == 'connection') commitBody = body;
          }
          return http.Response('{}', 200);
        }),
      );
      await auth.initialize();

      final sync = SyncService(
        db,
        auth,
        httpClient: MockClient((request) async => http.Response('', 200)),
      );
      sync.initializeEncryption('correct horse battery staple');

      await sync.syncOnClose();

      expect(commitBody, isNotNull,
          reason: 'the connection blob should have been uploaded');
      expect(commitBody!['isDeleted'], isTrue);
    });
  });

  group('Sync download does not requeue for re-upload', () {
    test('applying a downloaded person does not create a pending change',
        () async {
      SharedPreferences.setMockInitialValues({
        'auth_token': 'fake.token.value',
        'user_id': 'u1',
      });

      final db = createTestDatabaseService();
      await db.initialize();

      final remotePerson = Person(name: 'Grace Hopper');
      final encryptor = EncryptionService()
        ..initializeWithPassword('correct horse battery staple', 'u1');
      final encryptedBlob = encryptor.encryptString(jsonEncode(remotePerson.toJson()));

      final auth = AuthService(
        httpClient: MockClient((request) async {
          if (request.url.path == '/api/sync/updates') {
            return http.Response(
                jsonEncode({
                  'entries': [
                    {
                      'blobType': 'person',
                      'blobId': remotePerson.id,
                      's3Key': 'k1',
                      'version': 1,
                      'isDeleted': false,
                    }
                  ],
                  'latestVersion': 1,
                }),
                200);
          }
          if (request.url.path ==
              '/api/sync/download/person/${remotePerson.id}') {
            return http.Response(
                jsonEncode({'downloadUrl': 'https://s3.example.com/blob'}), 200);
          }
          return http.Response('{}', 200);
        }),
      );
      await auth.initialize();

      final sync = SyncService(
        db,
        auth,
        httpClient: MockClient((request) async => http.Response(encryptedBlob, 200)),
      );
      sync.initializeEncryption('correct horse battery staple');

      await sync.syncOnOpen();

      final saved = await db.getPerson(remotePerson.id);
      expect(saved, isNotNull, reason: 'the downloaded person should be saved locally');
      expect(saved!.name, 'Grace Hopper');

      expect(await db.getPendingChanges(), isEmpty,
          reason: 'saving data that just arrived FROM the server must not '
              'queue it to be uploaded straight back to it next sync');
    });

    test('DatabaseService.save* with recordPendingChange: false skips the pending change',
        () async {
      final db = createTestDatabaseService();
      await db.initialize();

      await db.savePerson(Person(name: 'No Pending'), recordPendingChange: false);
      expect(await db.getPendingChanges(), isEmpty);

      await db.savePerson(Person(name: 'Has Pending'));
      expect(await db.getPendingChanges(), isNotEmpty);
    });
  });
}
