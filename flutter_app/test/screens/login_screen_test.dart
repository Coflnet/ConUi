// Account sign-in is an optional route. Continuing without an account records
// that explicit choice and returns to the existing local app when pushed.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/screens/login_screen.dart';
import 'package:relationship_manager/services/auth_service.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/sync_service.dart';

import '../support/localized_app.dart';
import '../support/test_database.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('tapping "Continue without account" records the choice',
      (tester) async {
    late DatabaseService dbService;
    late AuthService authService;
    await tester.runAsync(() async {
      dbService = createTestDatabaseService();
      await dbService.initialize();
      authService = AuthService(
        httpClient: MockClient((request) async => http.Response('{}', 404)),
      );
      await authService.initialize();
    });

    final syncService = SyncService(dbService, authService);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: dbService),
          ChangeNotifierProvider(create: (_) => authService),
          ChangeNotifierProvider.value(value: syncService),
        ],
        child: wrapLocalized(const LoginScreen()),
      ),
    );

    // Flush the debug auto-login timer (see widget_test.dart for why not
    // pumpAndSettle) before it can race with the tap below.
    await tester.pump(const Duration(milliseconds: 600));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(find.textContaining('Could not sign in'), findsOneWidget);
    expect(authService.continuedWithoutAccount, isFalse);
    final signInButton = find.byKey(const Key('account-sign-in'));
    await tester.ensureVisible(signInButton);
    await tester.tap(signInButton);
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(authService.signInUnavailable, isTrue);
    expect(find.textContaining('Account sign-in is temporarily unavailable'),
        findsOneWidget);

    final continueButton = find.text('Continue without account');
    await tester.ensureVisible(continueButton);
    await tester.pump();
    await tester.tap(continueButton);
    await tester.pump();
    await tester.pump();

    expect(authService.continuedWithoutAccount, isTrue);
    expect(syncService.needsSignIn, isTrue);
  });

  testWidgets('shows German text with a German device locale', (tester) async {
    late DatabaseService dbService;
    late AuthService authService;
    await tester.runAsync(() async {
      dbService = createTestDatabaseService();
      await dbService.initialize();
      authService = AuthService(
        httpClient: MockClient((request) async => http.Response('{}', 404)),
      );
      await authService.initialize();
    });
    final syncService = SyncService(dbService, authService);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: dbService),
          ChangeNotifierProvider(create: (_) => authService),
          ChangeNotifierProvider.value(value: syncService),
        ],
        child: wrapLocalized(const LoginScreen(), locale: const Locale('de')),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }

    expect(find.text('Ohne Konto fortfahren'), findsOneWidget);
    expect(find.text('Entwicklungs-Anmeldung'), findsOneWidget);
    expect(find.textContaining('Die Anmeldung ist fehlgeschlagen'),
        findsOneWidget);
    // Nothing from the English strings must leak through.
    expect(find.text('Continue without account'), findsNothing);
    expect(find.text('Development Login'), findsNothing);
  });
  for (final locale in ['en', 'de']) {
    testWidgets(
        '$locale outage waits 120 seconds for a manual retry and keeps drafts',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'user_id': 'retained-profile',
        'encryption_salt': 'retained-salt',
        'continued_without_account': true,
      });
      var requests = 0;
      var browserLaunches = 0;
      late DatabaseService db;
      late AuthService auth;
      final draft =
          Event(title: 'Unsent local draft', dateTime: DateTime(2020));
      await tester.runAsync(() async {
        db = createTestDatabaseService();
        await db.initialize();
        await db.saveEvent(draft);
        auth = AuthService(
          httpClient: MockClient((request) async {
            if (request.url.path != '/api/auth/config') {
              return http.Response('{}', 404);
            }
            requests++;
            return requests == 1
                ? http.Response('{}', 503)
                : http.Response(
                    '{"enabled":true,"issuer":"https://identity.example/realm","clientId":"con-app"}',
                    200);
          }),
          beginSignIn: (_, __, ___) async {
            browserLaunches++;
            return null;
          },
        );
        await auth.initialize();
      });
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => auth),
          ChangeNotifierProvider.value(value: SyncService(db, auth)),
        ],
        child: wrapLocalized(const LoginScreen(), locale: Locale(locale)),
      ));
      await tester.pump(const Duration(milliseconds: 600));
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      await tester.enterText(
          find.byType(TextField).at(1), 'Unsaved name draft');
      final button = find.byKey(const Key('account-sign-in'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      String countdown(int seconds) => locale == 'en'
          ? 'Try again in $seconds ${seconds == 1 ? 'second' : 'seconds'}'
          : 'In $seconds ${seconds == 1 ? 'Sekunde' : 'Sekunden'} erneut versuchen';
      expect(auth.signInUnavailable, isTrue);
      expect(
          tester
              .widget<OutlinedButton>(find.byKey(const Key('email-sign-in')))
              .onPressed,
          isNull);
      expect(
          tester
              .widget<TextButton>(find.byKey(const Key('email-create-account')))
              .onPressed,
          isNull);
      expect(find.text(countdown(120)), findsOneWidget);
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(await auth.signIn(), isFalse);
      expect(requests, 1);
      await tester.pump(const Duration(seconds: 60));
      expect(find.text(countdown(60)), findsOneWidget);
      await tester.pump(const Duration(seconds: 59));
      expect(find.text(countdown(1)), findsOneWidget);
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      await tester.pump(const Duration(seconds: 1));
      expect(auth.signInRetrySeconds, 0);
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      expect(requests, 1, reason: 'expiry must not automatically retry');
      await tester.tap(button);
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      expect(requests, 2);
      expect(browserLaunches, 1);
      expect(find.text('Unsaved name draft'), findsOneWidget);
      expect(auth.userId, 'retained-profile');
      expect(auth.encryptionSalt, 'retained-salt');
      expect(auth.continuedWithoutAccount, isTrue);
      expect(auth.token, isNull);
      await tester.runAsync(() async {
        expect((await db.getEvent(draft.id))!.title, 'Unsent local draft');
        expect(await db.getPendingChanges(), hasLength(1));
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('user_id'), 'retained-profile');
        expect(prefs.getString('encryption_salt'), 'retained-salt');
      });
    });
  }
  for (final locale in ['en', 'de']) {
    testWidgets(
        '$locale Google and email choices pass explicit provider and share busy state',
        (tester) async {
      final choices = <(String?, bool, String)>[];
      var pending = Completer<String?>();
      final auth = AuthService(
        httpClient: MockClient((request) async => request.url.path ==
                '/api/auth/config'
            ? http.Response(
                '{"enabled":true,"issuer":"https://identity.example/realm","clientId":"con-app"}',
                200)
            : http.Response('{}', 404)),
        beginSignIn: (config, language, _) {
          choices
              .add((config.identityProvider, config.createAccount, language));
          return pending.future;
        },
      );
      addTearDown(auth.dispose);
      await tester.pumpWidget(MultiProvider(providers: [
        ChangeNotifierProvider<AuthService>.value(value: auth),
        ChangeNotifierProvider.value(
            value: SyncService(createTestDatabaseService(), auth)),
      ], child: wrapLocalized(const LoginScreen(), locale: Locale(locale))));
      await tester.pump(const Duration(milliseconds: 600));
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      final l10n =
          AppLocalizations.of(tester.element(find.byType(LoginScreen)));
      expect(find.text(l10n.loginGoogleHint), findsOneWidget);
      expect(find.text(l10n.loginGoogleButton), findsOneWidget);
      expect(find.text(l10n.loginEmailButton), findsOneWidget);
      expect(find.text(l10n.loginEmailCreateButton), findsOneWidget);
      for (final key in [
        'account-sign-in',
        'email-sign-in',
        'email-create-account'
      ]) {
        final button = find.byKey(Key(key));
        final callback = tester.widget<ButtonStyleButton>(button).onPressed!;
        callback();
        callback();
        await tester.pump();
        expect(choices.last, (
          key == 'account-sign-in' ? 'google' : '',
          key == 'email-create-account',
          locale
        ));
        for (final other in [
          'account-sign-in',
          'email-sign-in',
          'email-create-account'
        ]) {
          expect(
              tester
                  .widget<ButtonStyleButton>(find.byKey(Key(other)))
                  .onPressed,
              isNull);
        }
        pending.complete(null);
        for (var i = 0; i < 5; i++) {
          await tester.pump();
        }
        pending = Completer<String?>();
      }
      expect(choices, hasLength(3),
          reason: 'duplicate taps must not start another browser flow');
    });
  }
}
