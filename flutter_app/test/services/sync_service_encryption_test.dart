// Regression test for the bug found during reconnaissance: encryption used
// to only be initialized during the interactive login (SyncService.
// initializeEncryption, called from LoginScreen). After an app restart with
// a token restored from storage (no interactive login), encryption was
// never (re-)initialized, and SyncService's upload helpers fell back to
// `_encryption.isInitialized ? encrypt : jsonData` - silently uploading
// plaintext, defeating the whole point of encrypting data on-device before
// it syncs.
//
// The fix: syncOnOpen/syncOnClose refuse to run at all while
// needsEncryptionPassword is true (i.e. the user is signed in but hasn't
// supplied their password this session), and the upload/download helpers
// no longer have an unencrypted fallback path at all.
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
  // SyncService defers notifyListeners() through SchedulerBinding (to
  // avoid "setState during build"), which needs a Flutter binding even in
  // a plain, non-widget test.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'auth_token': 'fake.token.value',
      'user_id': 'u1',
    });
  });

  test(
      'sync is skipped (not uploaded unencrypted) when signed in but the password was never entered this session',
      () async {
    final db = createTestDatabaseService();
    await db.initialize();

    var authCalls = 0;
    final auth = AuthService(
      httpClient: MockClient((request) async {
        authCalls++;
        return http.Response('{}', 200);
      }),
    );
    await auth.initialize();
    expect(auth.isAuthenticated, isTrue);

    var s3Calls = 0;
    final sync = SyncService(
      db,
      auth,
      httpClient: MockClient((request) async {
        s3Calls++;
        return http.Response('', 200);
      }),
    );

    await db.savePerson(Person(name: 'Ada Lovelace'));
    expect((await db.getPendingChanges()), isNotEmpty);

    // Deliberately never call sync.initializeEncryption(...) - this is the
    // "restarted app, token restored, password not re-entered" scenario.
    expect(sync.needsEncryptionPassword, isFalse,
        reason: 'should not claim this before a sync was even attempted');

    await sync.syncOnClose();

    expect(sync.needsEncryptionPassword, isTrue);
    expect(authCalls, 0,
        reason: 'must not even negotiate an upload without a working key');
    expect(s3Calls, 0, reason: 'must not upload any blob without a working key');
    expect((await db.getPendingChanges()), isNotEmpty,
        reason: 'the pending change must survive, ready to sync once the '
            'password is available');
  });

  test('once the password is provided, sync proceeds and the blob is genuinely encrypted',
      () async {
    final db = createTestDatabaseService();
    await db.initialize();

    // syncOnClose uploads a blob per changed entity type plus the sync
    // index; key captured bytes by blobType (learned from the /upload
    // negotiation call that always immediately precedes the matching PUT)
    // so this test can single out the person blob specifically.
    final uploadsByType = <String, List<int>>{};
    String? pendingBlobType;

    final auth = AuthService(
      httpClient: MockClient((request) async {
        if (request.url.path == '/api/sync/upload') {
          pendingBlobType = jsonDecode(request.body)['blobType'] as String;
          return http.Response(
              jsonEncode({
                'uploadUrl': 'https://s3.example.com/put-url',
                's3Key': 'key123',
              }),
              200);
        }
        // /api/sync/commit and anything else.
        return http.Response('{}', 200);
      }),
    );
    await auth.initialize();

    final sync = SyncService(
      db,
      auth,
      httpClient: MockClient((request) async {
        expect(request.method, 'PUT');
        expect(request.url.toString(), 'https://s3.example.com/put-url');
        uploadsByType[pendingBlobType!] = request.bodyBytes;
        return http.Response('', 200);
      }),
    );

    final person = Person(name: 'Ada Lovelace');
    await db.savePerson(person);

    sync.initializeEncryption('correct horse battery staple');
    expect(sync.needsEncryptionPassword, isFalse);

    await sync.syncOnClose();

    expect(uploadsByType['person'], isNotNull,
        reason: 'the person blob should have been uploaded');
    final uploadedBody = utf8.decode(uploadsByType['person']!);
    final plainJson = jsonEncode(person.toJson());

    // Never uploaded as plaintext.
    expect(uploadedBody, isNot(equals(plainJson)));
    expect(uploadedBody.contains('Ada Lovelace'), isFalse);

    // But it genuinely IS that data, encrypted with the session's key -
    // decrypting it with the same password/salt recovers the original
    // JSON exactly.
    final decryptor = EncryptionService()..initializeWithPassword(
        'correct horse battery staple', auth.encryptionSalt ?? auth.userId!);
    expect(decryptor.decryptString(uploadedBody), plainJson);
  });

  for (final change in ['account', 'salt']) {
    test('changing $change blocks an old unlocked key before any sync request',
        () async {
      SharedPreferences.setMockInitialValues({
        'auth_token': 'first.token',
        'user_id': 'u1',
        'encryption_salt': 'first-salt',
      });
      final db = createTestDatabaseService();
      await db.initialize();
      var apiCalls = 0;
      var blobCalls = 0;
      final auth = AuthService(httpClient: MockClient((request) async {
        apiCalls++;
        return http.Response('{}', 200);
      }));
      await auth.initialize();
      final sync =
          SyncService(db, auth, httpClient: MockClient((request) async {
        blobCalls++;
        return http.Response('', 200);
      }));
      sync.initializeEncryption('first password');
      final person = Person(name: 'Private first-account story');
      await db.savePerson(person);
      final pendingIds =
          (await db.getPendingChanges()).map((c) => c.id).toList();
      final initialIndex = jsonEncode((await db.getSyncIndex())?.toJson());

      // Same salt with a different user still invalidates the account binding;
      // same user with a changed salt also needs a newly derived key.
      SharedPreferences.setMockInitialValues({
        'auth_token': 'second.token',
        'user_id': change == 'account' ? 'u2' : 'u1',
        'encryption_salt': change == 'salt' ? 'second-salt' : 'first-salt',
      });
      await auth.initialize();
      await sync.syncOnOpen();
      await sync.syncOnClose();
      await sync.fullSync();
      expect(sync.needsEncryptionPassword, isTrue);
      expect(apiCalls, 0);
      expect(blobCalls, 0);
      expect((await db.getPendingChanges()).map((c) => c.id), pendingIds);
      expect((await db.getPerson(person.id))!.name, person.name);
      expect(jsonEncode((await db.getSyncIndex())?.toJson()), initialIndex);

      // Observing another identity locks this session even if it switches back.
      SharedPreferences.setMockInitialValues({
        'auth_token': 'first.token',
        'user_id': 'u1',
        'encryption_salt': 'first-salt',
      });
      await auth.initialize();
      await sync.syncOnClose();
      expect(sync.needsEncryptionPassword, isTrue);
      expect(apiCalls, 0);
      expect(blobCalls, 0);
    });
  }

  test('token refresh for the same user and salt preserves the unlocked key',
      () async {
    final db = createTestDatabaseService();
    await db.initialize();
    var apiCalls = 0;
    final auth = AuthService(httpClient: MockClient((request) async {
      apiCalls++;
      expect(request.url.path, '/api/sync/updates');
      return http.Response(
          jsonEncode({'entries': [], 'latestVersion': 0}), 200);
    }));
    await auth.initialize();
    final sync = SyncService(db, auth);
    sync.initializeEncryption('password');
    SharedPreferences.setMockInitialValues(
        {'auth_token': 'refreshed.token', 'user_id': 'u1'});
    await auth.initialize();
    await sync.syncOnOpen();
    expect(sync.needsEncryptionPassword, isFalse);
    expect(apiCalls, 1);
  });

  for (final switchAt in ['upload', 'blob', 'commit', 'reunlock']) {
    test('account change during $switchAt aborts upload before another request',
        () async {
      SharedPreferences.setMockInitialValues({
        'auth_token': 'first.token',
        'user_id': 'u1',
        'encryption_salt': 'first-salt',
      });
      final db = createTestDatabaseService();
      await db.initialize();
      await db.saveSyncIndex(SyncIndex(lastSyncTimestamp: 8));
      await db.savePerson(Person(name: 'Private first-account story'));
      final pendingIds =
          (await db.getPendingChanges()).map((c) => c.id).toList();
      final initialIndex = jsonEncode((await db.getSyncIndex())?.toJson());
      late AuthService auth;
      late SyncService sync;
      var apiCalls = 0;
      var blobCalls = 0;
      Future<void> switchAccount() async {
        SharedPreferences.setMockInitialValues({
          'auth_token': 'second.token',
          'user_id': 'u2',
          'encryption_salt': 'second-salt',
        });
        await auth.initialize();
        if (switchAt == 'reunlock') {
          sync.initializeEncryption('second password');
        }
      }

      auth = AuthService(httpClient: MockClient((request) async {
        apiCalls++;
        expect(request.headers['Authorization'], 'Bearer first.token');
        if (request.url.path == '/api/sync/upload') {
          if (switchAt == 'upload' || switchAt == 'reunlock') {
            await switchAccount();
          }
          return http.Response(
              jsonEncode(
                  {'uploadUrl': 'https://storage.test/put', 's3Key': 'key'}),
              200);
        }
        expect(request.url.path, '/api/sync/commit');
        if (switchAt == 'commit') await switchAccount();
        return http.Response('{}', 200);
      }));
      await auth.initialize();
      sync = SyncService(db, auth, httpClient: MockClient((request) async {
        blobCalls++;
        if (switchAt == 'blob') await switchAccount();
        return http.Response('', 200);
      }))
        ..initializeEncryption('first password');
      await sync.syncOnClose();
      expect(apiCalls, switchAt == 'commit' ? 2 : 1);
      expect(blobCalls, ['upload', 'reunlock'].contains(switchAt) ? 0 : 1);
      expect((await db.getPendingChanges()).map((c) => c.id), pendingIds);
      expect(jsonEncode((await db.getSyncIndex())?.toJson()), initialIndex);
      expect(sync.lastSyncTime, isNull);
      expect(sync.lastError, contains('Account or encryption changed'));
      expect(sync.needsEncryptionPassword, switchAt != 'reunlock');
      expect(sync.isSyncing, isFalse);
    });
  }

  for (final switchAt in ['updates', 'download']) {
    test('salt change during $switchAt cannot apply a stale download or cursor',
        () async {
      SharedPreferences.setMockInitialValues({
        'auth_token': 'first.token',
        'user_id': 'u1',
        'encryption_salt': 'first-salt',
      });
      final db = createTestDatabaseService();
      await db.initialize();
      await db.saveSyncIndex(SyncIndex(lastSyncTimestamp: 8));
      final initialIndex = jsonEncode((await db.getSyncIndex())?.toJson());
      final remote = Person(id: 'remote-person', name: 'Private remote story');
      late AuthService auth;
      late String encrypted;
      var apiCalls = 0;
      var blobCalls = 0;
      Future<void> changeSalt() async {
        SharedPreferences.setMockInitialValues({
          'auth_token': 'second.token',
          'user_id': 'u1',
          'encryption_salt': 'second-salt',
        });
        await auth.initialize();
      }

      auth = AuthService(httpClient: MockClient((request) async {
        apiCalls++;
        expect(request.headers['Authorization'], 'Bearer first.token');
        if (request.url.path == '/api/sync/updates') {
          // Full download starts at zero without first changing the saved cursor.
          expect(jsonDecode(request.body)['lastSyncVersion'], 0);
          if (switchAt == 'updates') await changeSalt();
          return http.Response(
              jsonEncode({
                'entries': [
                  {
                    'blobType': 'person',
                    'blobId': remote.id,
                    's3Key': 'key',
                    'version': 9
                  }
                ],
                'latestVersion': 9
              }),
              200);
        }
        return http.Response(
            jsonEncode({'downloadUrl': 'https://storage.test/blob'}), 200);
      }));
      await auth.initialize();
      final sync =
          SyncService(db, auth, httpClient: MockClient((request) async {
        blobCalls++;
        await changeSalt();
        return http.Response(encrypted, 200);
      }))
            ..initializeEncryption('first password');
      encrypted = EncryptionService.instance!.encryptJson(remote.toJson());
      await sync.forceFullSync();
      expect(apiCalls, switchAt == 'updates' ? 1 : 2);
      expect(blobCalls, switchAt == 'updates' ? 0 : 1);
      expect(await db.getPerson(remote.id), isNull);
      expect(jsonEncode((await db.getSyncIndex())?.toJson()), initialIndex);
      expect(sync.needsEncryptionPassword, isTrue);
      expect(sync.lastSyncTime, isNull);
      expect(sync.lastError, contains('Account or encryption changed'));
      expect(sync.isSyncing, isFalse);
    });
  }
}
