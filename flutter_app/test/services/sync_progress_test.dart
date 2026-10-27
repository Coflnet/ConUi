import 'dart:async';
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
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({
        'auth_token': 'fake.token.value',
        'user_id': 'u1',
      }));

  testWidgets(
      'download counts applied metadata, ignores orphan chunks and resets on retry',
      (tester) async {
    await tester.runAsync(() async {
      final db = createTestDatabaseService();
      await db.initialize();
      final encryption = EncryptionService();
      await encryption.initializeWithPassword('password', 'u1');
      final people = [
        Person(id: 'a', name: 'Anna'),
        Person(id: 'b', name: 'Bert')
      ];
      final encrypted = <String, String>{};
      for (final person in people) {
        encrypted[person.id] =
            await encryption.encryptString(jsonEncode(person.toJson()));
      }
      var started = Completer<void>();
      var release = Completer<void>();
      var fail = true;
      final auth = AuthService(httpClient: MockClient((request) async {
        if (request.url.path == '/api/sync/updates') {
          started.complete();
          await release.future;
          return http.Response(
              jsonEncode({
                'entries': [
                  for (final person in people)
                    {
                      'blobType': 'person',
                      'blobId': person.id,
                      's3Key': 'key',
                      'version': 1
                    },
                  {
                    'blobType': 'recording_chunk_v1',
                    'blobId': 'orphan',
                    's3Key': 'key',
                    'version': 1
                  }
                ],
                'latestVersion': 1
              }),
              200);
        }
        return http.Response(
            jsonEncode({
              'downloadUrl':
                  'https://storage.test/${request.url.pathSegments.last}'
            }),
            200);
      }));
      await auth.initialize();
      final gates = [Completer<void>(), Completer<void>()];
      final arrivals = [Completer<void>(), Completer<void>()];
      final sync =
          SyncService(db, auth, httpClient: MockClient((request) async {
        final index = request.url.path == '/a' ? 0 : 1;
        arrivals[index].complete();
        await gates[index].future;
        return http.Response(
            encrypted[people[index].id]!, fail && index == 1 ? 503 : 200);
      }));
      await sync.initializeEncryption('password');
      var notices = 0;
      sync.addListener(() => notices++);
      var task = sync.syncOnOpen();
      await started.future;
      expect(sync.phase, SyncPhase.preparing);
      expect(sync.completedItems, 0);
      expect(sync.estimatedRemaining, isNull);
      release.complete();
      await arrivals[0].future;
      expect(sync.phase, SyncPhase.downloading);
      expect(sync.totalItems, 2);
      expect(sync.completedItems, 0);
      gates[0].complete();
      await arrivals[1].future;
      expect(sync.completedItems, 1);
      expect(sync.estimatedRemaining, isNotNull);
      expect(binding.hasScheduledFrame, isTrue);
      await tester.pump();
      expect(notices, greaterThan(0));
      gates[1].complete();
      await task;
      expect(sync.lastError, contains('503'));
      expect(sync.completedItems, 1);
      expect(sync.lastSyncTime, isNull);
      expect(sync.estimatedRemaining, isNull);
      expect(await db.getSyncIndex(), isNull);

      fail = false;
      started = Completer<void>();
      release = Completer<void>();
      for (var i = 0; i < 2; i++) {
        arrivals[i] = Completer<void>();
        gates[i] = Completer<void>();
      }
      task = sync.syncOnOpen();
      await started.future;
      expect(sync.phase, SyncPhase.preparing);
      expect(sync.completedItems, 0);
      expect(sync.totalItems, 0);
      release.complete();
      await arrivals[0].future;
      gates[0].complete();
      await arrivals[1].future;
      gates[1].complete();
      await task;
      expect(sync.lastError, isNull);
      expect(sync.phase, SyncPhase.finishing);
      expect((await db.getSyncIndex())!.lastSyncTimestamp, 1);
      expect(sync.lastSyncTime, isNotNull);
    });
  });

  test(
      'upload counts committed blobs and month groups, failed index never advances',
      () async {
    final db = createTestDatabaseService();
    await db.initialize();
    await db.savePerson(Person(id: 'a', name: 'Anna'));
    await db.saveEvent(Event(title: 'First', dateTime: DateTime(1952)));
    await db.saveEvent(Event(title: 'Second', dateTime: DateTime(1952)));
    var fail = true;
    final arrivals = List.generate(3, (_) => Completer<void>());
    final gates = List.generate(3, (_) => Completer<void>());
    var commitIndex = 0;
    final auth = AuthService(httpClient: MockClient((request) async {
      if (request.url.path == '/api/sync/upload') {
        return http.Response(
            jsonEncode(
                {'uploadUrl': 'https://storage.test/blob', 's3Key': 'key'}),
            200);
      }
      final index = commitIndex++;
      if (fail) {
        arrivals[index].complete();
        await gates[index].future;
      }
      return http.Response('{}', fail && index == 2 ? 503 : 200);
    }));
    await auth.initialize();
    final sync = SyncService(db, auth,
        httpClient: MockClient((_) async => http.Response('', 200)));
    await sync.initializeEncryption('password');
    final task = sync.syncOnClose();
    for (var i = 0; i < 3; i++) {
      await arrivals[i].future;
      expect(sync.phase, SyncPhase.uploading);
      expect(sync.totalItems, 3);
      expect(sync.completedItems, i);
      gates[i].complete();
    }
    await task;
    expect(sync.completedItems, 2);
    expect(sync.lastError, contains('503'));
    expect(await db.getPendingChanges(), hasLength(3));
    fail = false;
    await sync.syncOnClose();
    expect(sync.lastError, isNull);
    expect(sync.phase, SyncPhase.finishing);
    expect(await db.getPendingChanges(), isEmpty);
  });
}
