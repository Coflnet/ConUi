import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/services/auth_service.dart';
import 'package:relationship_manager/services/encryption_service.dart';
import 'package:relationship_manager/services/sync_service.dart';
import 'package:relationship_manager/widgets/sync_prompt.dart';

import '../support/test_database.dart';

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 50; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
}

Widget app(SyncService sync, AuthService auth) => MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: sync),
        ChangeNotifierProvider.value(value: auth),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
            builder: (context) => Scaffold(
                    body: TextButton(
                  onPressed: () => syncWithPrompts(context),
                  child: const Text('Sync now'),
                ))),
      ),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({
        'auth_token': 'fake.token.value',
        'user_id': 'u1',
      }));

  testWidgets(
      'locked sync offers password input; cancel and empty input send nothing',
      (tester) async {
    final db = createTestDatabaseService();
    await tester.runAsync(db.initialize);
    var requests = 0;
    final auth = AuthService(httpClient: MockClient((_) async {
      requests++;
      return http.Response('{}', 200);
    }));
    await tester.runAsync(auth.initialize);
    final sync = SyncService(db, auth);
    await tester.pumpWidget(app(sync, auth));
    await tester.tap(find.text('Sync now'));
    await tester.pumpAndSettle();
    expect(find.text('Unlock encrypted sync'), findsOneWidget);
    await tester.tap(find.text('Unlock and sync'));
    await tester.pumpAndSettle();
    expect(find.text('Enter your encryption password.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(requests, 0);
    expect(sync.isUnlocked, isFalse);
  });

  testWidgets(
      'wrong password preserves input and prevents uploads; correct retry resumes sync',
      (tester) async {
    final db = createTestDatabaseService();
    final remote = Person(id: 'remote', name: 'Remote person');
    final cipher = EncryptionService()
      ..initializeWithPassword('right-password', 'u1');
    final encrypted = cipher.encryptJson(remote.toJson());
    await tester.runAsync(() async {
      await db.initialize();
      await db.savePerson(Person(id: 'local', name: 'Local person'));
    });
    var uploads = 0;
    final auth = AuthService(httpClient: MockClient((r) async {
      if (r.url.path == '/api/sync/updates') {
        return http.Response(
            jsonEncode({
              'entries': [
                {
                  'blobType': 'person',
                  'blobId': remote.id,
                  's3Key': 'remote-key',
                  'version': 1
                }
              ],
              'latestVersion': 1,
            }),
            200);
      }
      if (r.url.path.startsWith('/api/sync/download/')) {
        return http.Response(
            '{"downloadUrl":"https://storage.test/read"}', 200);
      }
      if (r.url.path == '/api/sync/upload') {
        return http.Response(
            '{"uploadUrl":"https://storage.test/write","s3Key":"local-key"}',
            200);
      }
      return http.Response('{}', 200);
    }));
    await tester.runAsync(auth.initialize);
    final sync = SyncService(db, auth, httpClient: MockClient((r) async {
      if (r.method == 'GET') return http.Response(encrypted, 200);
      uploads++;
      expect(r.body, startsWith('con:v1:'));
      return http.Response('', 200);
    }));
    await tester.pumpWidget(app(sync, auth));
    await tester.tap(find.text('Sync now'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'wrong-password');
    await tester.runAsync(() async {
      final action = tester
          .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Unlock and sync'))
          .onPressed as dynamic;
      await action();
    });
    await settle(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not unlock and sync.'), findsOneWidget);
    expect(find.text('wrong-password'), findsOneWidget);
    expect(uploads, 0);
    expect(sync.isUnlocked, isFalse);
    expect(await tester.runAsync(db.getPendingChanges), isNotEmpty);
    await tester.enterText(find.byType(TextFormField), 'right-password');
    await tester.runAsync(() async {
      final action = tester
          .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Unlock and sync'))
          .onPressed as dynamic;
      await action();
    });
    await settle(tester);
    await tester.pumpAndSettle();
    expect(sync.lastError, isNull);
    expect(sync.isSyncing, isFalse);
    expect(sync.isUnlocked, isTrue);
    expect(find.text('Unlock encrypted sync'), findsNothing);
    expect(sync.isUnlocked, isTrue);
    expect(sync.lastError, isNull);
    expect(uploads, greaterThan(0));
    expect(await tester.runAsync(db.getPendingChanges), isEmpty);
    expect((await tester.runAsync(() => db.getPerson('remote')))!.name,
        'Remote person');
  });
}
