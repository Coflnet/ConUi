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

const capabilities = {
  'version': 1,
  'maxEntries': 128,
  'maxPayloadBytes': 4194304,
  'canUploadPacks': true,
};

http.Response updates(
        {List<dynamic> entries = const [],
        int version = 0,
        Map<String, dynamic>? batching = capabilities}) =>
    http.Response(
        jsonEncode({
          'entries': entries,
          'latestVersion': version,
          if (batching != null) 'batching': batching,
        }),
        200);

http.Response uploadUrl() => http.Response(
    jsonEncode({
      'uploadUrl': 'https://storage.test/blob',
      's3Key': 'key',
    }),
    200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({
        'auth_token': 'fake.token.value',
        'user_id': 'u1',
      }));

  test(
      'packs 128 logical records per request, deduplicates snapshots and preserves in-flight edits',
      () async {
    final db = createTestDatabaseService();
    await db.initialize();
    for (var i = 0; i < 129; i++) {
      await db.savePerson(Person(id: 'p$i', name: 'Person $i'));
    }
    await db.savePerson(Person(id: 'p0', name: 'Newest snapshot'));
    // A downloaded row must not replace the pending local payload.
    await db.savePerson(Person(id: 'p0', name: 'Remote row'),
        recordPendingChange: false);
    final packs = <List<dynamic>>[];
    final auth = AuthService(httpClient: MockClient((request) async {
      switch (request.url.path) {
        case '/api/sync/updates':
          return updates();
        case '/api/sync/upload/batch':
          packs.add(jsonDecode(request.body)['entries'] as List);
          if (packs.length == 1) {
            await db.savePerson(Person(id: 'p0', name: 'In flight edit'));
          }
          return http.Response('{}', 200);
        case '/api/sync/upload':
          expect(jsonDecode(request.body)['blobType'], 'index');
          return uploadUrl();
        default:
          return http.Response('{}', 200);
      }
    }));
    await auth.initialize();
    final sync = SyncService(db, auth,
        httpClient: MockClient((_) async => http.Response('', 200)));
    await sync.initializeEncryption('password');
    await sync.syncOnOpen();
    await sync.syncOnClose();
    expect(sync.lastError, isNull);
    expect(packs.map((p) => p.length), [128, 1]);
    final encryptor = EncryptionService();
    await encryptor.initializeWithPassword('password', 'u1');
    final first = packs.first.first as Map;
    expect(jsonDecode(await encryptor.decryptString(first['data']))['name'],
        'Newest snapshot');
    expect(
        (await db.getPendingChanges()).single.data['name'], 'In flight edit');
  });

  for (final status in [404, 405, 501, 503]) {
    test('batch status $status only falls back when explicitly unsupported',
        () async {
      final db = createTestDatabaseService();
      await db.initialize();
      await db.savePerson(Person(name: 'Local'));
      var legacy = 0;
      final auth = AuthService(httpClient: MockClient((request) async {
        switch (request.url.path) {
          case '/api/sync/updates':
            return updates();
          case '/api/sync/upload/batch':
            return http.Response('{}', status);
          case '/api/sync/upload':
            legacy++;
            return uploadUrl();
          default:
            return http.Response('{}', 200);
        }
      }));
      await auth.initialize();
      final sync = SyncService(db, auth,
          httpClient: MockClient((_) async => http.Response('', 200)));
      await sync.initializeEncryption('password');
      await sync.syncOnOpen();
      await sync.syncOnClose();
      expect(legacy, status == 503 ? 0 : 2);
      expect(
          await db.getPendingChanges(), status == 503 ? hasLength(1) : isEmpty);
    });
  }

  test('failed final index retains every packed pending change', () async {
    final db = createTestDatabaseService();
    await db.initialize();
    await db.savePerson(Person(name: 'Local'));
    final auth = AuthService(httpClient: MockClient((request) async {
      switch (request.url.path) {
        case '/api/sync/updates':
          return updates();
        case '/api/sync/upload':
          return uploadUrl();
        case '/api/sync/commit':
          return http.Response('{}', 503);
        default:
          return http.Response('{}', 200);
      }
    }));
    await auth.initialize();
    final sync = SyncService(db, auth,
        httpClient: MockClient((_) async => http.Response('', 200)));
    await sync.initializeEncryption('password');
    await sync.syncOnOpen();
    await sync.syncOnClose();
    expect(sync.lastError, contains('503'));
    expect(await db.getPendingChanges(), hasLength(1));
  });

  for (final shouldFail in [false, true]) {
    test(
        'batch download inline and URL payloads ${shouldFail ? 'hold cursor on failure' : 'apply without requeue'}',
        () async {
      final db = createTestDatabaseService();
      await db.initialize();
      await db.saveSyncIndex(SyncIndex(lastSyncTimestamp: 8));
      final encryptor = EncryptionService();
      await encryptor.initializeWithPassword('password', 'u1');
      final people = [
        Person(id: 'p1', name: 'One'),
        Person(id: 'p2', name: 'Two')
      ];
      final encrypted = await Future.wait(
          people.map((p) => encryptor.encryptString(jsonEncode(p.toJson()))));
      final auth = AuthService(httpClient: MockClient((request) async {
        switch (request.url.path) {
          case '/api/sync/updates':
            return updates(version: 10, entries: [
              for (var i = 0; i < people.length; i++)
                {
                  'blobType': 'person',
                  'blobId': people[i].id,
                  's3Key': 'key',
                  'version': 9 + i,
                },
            ]);
          case '/api/sync/download/batch':
            expect(jsonDecode(request.body)['entries'], hasLength(2));
            return http.Response(
                jsonEncode({
                  'entries': [
                    {
                      'blobType': 'person',
                      'blobId': 'p1',
                      'version': 9,
                      'data': encrypted[0]
                    },
                    {
                      'blobType': 'person',
                      'blobId': 'p2',
                      'version': 10,
                      'downloadUrl': 'https://storage.test/blob'
                    },
                  ]
                }),
                200);
          default:
            fail('Unexpected request ${request.url.path}');
        }
      }));
      await auth.initialize();
      final sync = SyncService(db, auth,
          httpClient: MockClient((_) async => http.Response(
              shouldFail ? 'invalid ciphertext' : encrypted[1], 200)));
      await sync.initializeEncryption('password');
      await sync.syncOnOpen();
      expect((await db.getSyncIndex())!.lastSyncTimestamp, shouldFail ? 8 : 10);
      expect(sync.lastError, shouldFail ? isNotNull : isNull);
      if (!shouldFail) expect((await db.getPerson('p2'))!.name, 'Two');
      expect(await db.getPendingChanges(), isEmpty);
    });
  }
  test('byte cap splits packs and sends an oversized entity through legacy',
      () async {
    final db = createTestDatabaseService();
    await db.initialize();
    for (var i = 0; i < 3; i++) {
      await db.savePerson(Person(id: 'p$i', name: 'Small'));
    }
    await db.savePerson(Person(id: 'large', name: 'x' * 3000));
    final packed = <dynamic>[];
    final legacy = <String>[];
    final auth = AuthService(httpClient: MockClient((request) async {
      switch (request.url.path) {
        case '/api/sync/updates':
          return updates(batching: {...capabilities, 'maxPayloadBytes': 1000});
        case '/api/sync/upload/batch':
          final entries = jsonDecode(request.body)['entries'] as List;
          expect(
              entries.fold<int>(
                  0, (sum, e) => sum + utf8.encode(e['data'] as String).length),
              lessThanOrEqualTo(1000));
          packed.addAll(entries);
          return http.Response('{}', 200);
        case '/api/sync/upload':
          legacy.add(jsonDecode(request.body)['blobId'] as String);
          return uploadUrl();
        default:
          return http.Response('{}', 200);
      }
    }));
    await auth.initialize();
    final sync = SyncService(db, auth,
        httpClient: MockClient((_) async => http.Response('', 200)));
    await sync.initializeEncryption('password');
    await sync.syncOnOpen();
    await sync.syncOnClose();
    expect(sync.lastError, isNull);
    expect(packed, hasLength(3));
    expect(legacy, ['large', 'main']);
    expect(await db.getPendingChanges(), isEmpty);
  });

  test('concurrent batch tombstone applies without a ciphertext or URL',
      () async {
    final db = createTestDatabaseService();
    await db.initialize();
    await db.savePerson(Person(id: 'p1', name: 'Old'),
        recordPendingChange: false);
    final auth = AuthService(httpClient: MockClient((request) async {
      if (request.url.path == '/api/sync/updates') {
        return updates(version: 9, entries: [
          {
            'blobType': 'person',
            'blobId': 'p1',
            's3Key': 'key',
            'version': 9,
          }
        ]);
      }
      expect(request.url.path, '/api/sync/download/batch');
      return http.Response(
          jsonEncode({
            'entries': [
              {
                'blobType': 'person',
                'blobId': 'p1',
                'version': 10,
                'isDeleted': true,
              }
            ]
          }),
          200);
    }));
    await auth.initialize();
    final sync = SyncService(db, auth,
        httpClient:
            MockClient((_) async => throw StateError('No blob needed')));
    await sync.initializeEncryption('password');
    await sync.syncOnOpen();
    expect(sync.lastError, isNull);
    expect((await db.getPerson('p1'))!.isDeleted, isTrue);
    expect((await db.getSyncIndex())!.lastSyncTimestamp, 9);
    expect(await db.getPendingChanges(), isEmpty);
  });
  for (final batching in [
    null,
    {...capabilities, 'canUploadPacks': false}
  ]) {
    test(
        'legacy uploads deduplicate snapshots when packs are unavailable ($batching)',
        () async {
      final db = createTestDatabaseService();
      await db.initialize();
      await db.savePerson(Person(id: 'p1', name: 'Local'));
      await db.deletePerson('p1');
      await db.savePerson(Person(id: 'p1', name: 'Remote'),
          recordPendingChange: false);
      final commits = <dynamic>[];
      final auth = AuthService(httpClient: MockClient((request) async {
        switch (request.url.path) {
          case '/api/sync/updates':
            return updates(batching: batching);
          case '/api/sync/upload':
            return uploadUrl();
          case '/api/sync/commit':
            commits.add(jsonDecode(request.body));
            return http.Response('{}', 200);
          default:
            fail('Unexpected request ${request.url.path}');
        }
      }));
      await auth.initialize();
      final sync = SyncService(db, auth,
          httpClient: MockClient((_) async => http.Response('', 200)));
      await sync.initializeEncryption('password');
      await sync.syncOnOpen();
      await sync.syncOnClose();
      expect(sync.lastError, isNull);
      expect(commits.where((entry) => entry['blobType'] == 'person'),
          hasLength(1));
      expect(commits.first['isDeleted'], isTrue);
      expect(await db.getPendingChanges(), isEmpty);
    });
  }
  for (final wrongPassword in [false, true]) {
    test(
        'batch URLs fetch one record at a time (wrong password: $wrongPassword)',
        () async {
      final db = createTestDatabaseService();
      await db.initialize();
      final encryptor = EncryptionService();
      await encryptor.initializeWithPassword('password', 'u1');
      final encrypted = await encryptor
          .encryptString(jsonEncode(Person(id: 'p1', name: 'First').toJson()));
      final fetched = <String>[];
      final auth = AuthService(httpClient: MockClient((request) async {
        if (request.url.path == '/api/sync/updates') {
          return updates(version: 9, entries: [
            for (final id in ['p1', 'p2'])
              {
                'blobType': 'person',
                'blobId': id,
                's3Key': 'key',
                'version': 9,
              }
          ]);
        }
        return http.Response(
            jsonEncode({
              'entries': [
                for (final id in ['p1', 'p2'])
                  {
                    'blobType': 'person',
                    'blobId': id,
                    'version': 9,
                    'downloadUrl': 'https://storage.test/$id',
                  }
              ]
            }),
            200);
      }));
      await auth.initialize();
      final sync =
          SyncService(db, auth, httpClient: MockClient((request) async {
        fetched.add(request.url.path);
        if (request.url.path == '/p2') {
          expect((await db.getPerson('p1'))!.name, 'First',
              reason: 'first record is applied before fetching the second URL');
          return http.Response('bad second ciphertext', 200);
        }
        return http.Response(encrypted, 200);
      }));
      await sync
          .initializeEncryption(wrongPassword ? 'wrong password' : 'password');
      await sync.syncOnOpen();
      expect(fetched, wrongPassword ? ['/p1'] : ['/p1', '/p2']);
      expect(sync.lastError, isNotNull);
      expect(await db.getSyncIndex(), isNull);
    });
  }
}
