import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

Widget app(SyncService sync, AuthService auth, {String locale = 'en'}) => MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: sync),
        ChangeNotifierProvider.value(value: auth),
      ],
      child: MaterialApp(
        locale: Locale(locale),
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
    final cipher = EncryptionService();
    await tester.runAsync(
        () => cipher.initializeWithPassword('right-password', 'u1'));
    final encrypted =
        (await tester.runAsync(() => cipher.encryptJson(remote.toJson())))!;
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

  testWidgets('download notifications preserve password field before failure',
      (tester) async {
    final db = createTestDatabaseService();
    final cipher = EncryptionService();
    await tester.runAsync(() async {
      await db.initialize();
      await cipher.initializeWithPassword('vault-password', 'u1');
    });
    final encrypted = (await tester.runAsync(() =>
        cipher.encryptJson(Person(id: 'first', name: 'First').toJson())))!;
    final reached =
        (await tester.runAsync(() async => Completer<void>()))!;
    final release =
        (await tester.runAsync(() async => Completer<void>()))!;
    final auth = AuthService(httpClient: MockClient((request) async {
      if (request.url.path == '/api/sync/updates') {
        return http.Response(
            jsonEncode({
              'entries': [
                for (final id in ['first', 'second'])
                  {
                    'blobType': 'person',
                    'blobId': id,
                    's3Key': id,
                    'version': 1
                  }
              ],
              'latestVersion': 1,
            }),
            200);
      }
      return http.Response(
          jsonEncode({
            'downloadUrl':
                'https://storage.test/${request.url.path.split('/').last}'
          }),
          200);
    }));
    await tester.runAsync(auth.initialize);
    final sync = SyncService(db, auth, httpClient: MockClient((request) async {
      if (request.url.path == '/first') return http.Response(encrypted, 200);
      reached.complete();
      await release.future;
      return http.Response('', 503);
    }));
    await tester.pumpWidget(app(sync, auth));
    await tester.tap(find.text('Sync now'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'vault-password');
    final field = tester.state<EditableTextState>(find.byType(EditableText));
    Future<void>? pending;
    await tester.runAsync(() async {
      final action = tester
          .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Unlock and sync'))
          .onPressed as dynamic;
      pending = action() as Future<void>;
      await reached.future.timeout(const Duration(seconds: 20), onTimeout: () {
        throw StateError('Download gate not reached: ${sync.lastError}');
      });
    });
    await tester.pump();
    await tester.pump();
    expect(find.text('Downloading 1 of 2 items (50%)'), findsOneWidget);
    expect(tester.state<EditableTextState>(find.byType(EditableText)),
        same(field));
    expect(field.widget.controller.text, 'vault-password');
    await tester.runAsync(() async {
      release.complete();
      await pending;
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not unlock and sync.'), findsOneWidget);
    expect(field.widget.controller.text, 'vault-password');
    expect(sync.isUnlocked, isFalse);
  });

  for (final locale in ['en', 'de']) {
    testWidgets('autofill survives storage outage and retry ($locale)', (
      tester,
    ) async {
      final db = createTestDatabaseService();
      await tester.runAsync(db.initialize);
      var unavailable = true;
      var requests = 0;
      final auth = AuthService(
        httpClient: MockClient((request) async {
          requests++;
          expect(request.url.path, '/api/sync/updates');
          return unavailable
              ? http.Response(
                  '{"slug":"storage_unavailable","message":"private backend details"}',
                  503,
                )
              : http.Response('{"entries":[],"latestVersion":0}', 200);
        }),
      );
      await tester.runAsync(auth.initialize);
      final sync = SyncService(db, auth);
      await tester.pumpWidget(app(sync, auth, locale: locale));
      await tester.tap(find.text('Sync now'));
      await tester.pumpAndSettle();
      final group = tester.state<AutofillGroupState>(
        find.byType(AutofillGroup),
      );
      final field = tester.state<EditableTextState>(find.byType(EditableText));
      expect(field.widget.autofillHints, [AutofillHints.password]);
      expect(group.autofillClients.single.autofillId, field.autofillId);
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/textinput',
        const JSONMethodCodec().encodeMethodCall(
          MethodCall('TextInputClient.updateEditingStateWithTag', [
            0,
            {
              field.autofillId: const TextEditingValue(
                text: 'vault-password',
              ).toJSON(),
            },
          ]),
        ),
        (_) {},
      );
      await tester.pump();
      expect(field.widget.controller.text, 'vault-password');
      field.widget.focusNode.unfocus();
      await tester.pump();
      field.widget.focusNode.requestFocus();
      await tester.pump();
      final actionLabel = locale == 'de'
          ? 'Entsperren und synchronisieren'
          : 'Unlock and sync';
      Future<void> submit() => tester.runAsync(() async {
        final action =
            tester
                    .widget<FilledButton>(
                      find.widgetWithText(FilledButton, actionLabel),
                    )
                    .onPressed
                as dynamic;
        await action();
      });
      await submit();
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          locale == 'de'
              ? 'Der Speicher für die Synchronisierung ist vorübergehend nicht verfügbar.'
              : 'Sync storage is temporarily unavailable.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('private backend details'), findsNothing);
      expect(field.widget.controller.text, 'vault-password');
      expect(
        tester.state<AutofillGroupState>(find.byType(AutofillGroup)),
        same(group),
      );
      expect(sync.isUnlocked, isFalse);
      expect(requests, 1);
      expect(
        tester.testTextInput.log.where(
          (call) =>
              call.method == 'TextInput.finishAutofillContext' &&
              call.arguments == true,
        ),
        isEmpty,
      );
      unavailable = false;
      await submit();
      await tester.pumpAndSettle();
      expect(sync.isUnlocked, isTrue);
      expect(requests, 2);
      expect(find.byType(AutofillGroup), findsNothing);
      expect(
        tester.testTextInput.log,
        contains(
          isMethodCall('TextInput.finishAutofillContext', arguments: true),
        ),
      );
    });
  }
}
