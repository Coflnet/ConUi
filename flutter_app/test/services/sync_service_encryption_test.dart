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
}
