import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/services/auth_service.dart';
import 'package:relationship_manager/widgets/account_required_dialog.dart';

import '../support/localized_app.dart';

class _Auth extends AuthService {
  final attempts = <bool>[];
  final providers = <String?>[];
  final locales = <String>[];
  Completer<bool>? pending;
  int retrySeconds = 0;
  @override
  int get signInRetrySeconds => retrySeconds;
  bool authenticated = false;
  bool succeeds = true;
  @override
  bool get isAuthenticated => authenticated;
  @override
  Future<bool> signIn(
      {String locale = 'de',
      bool createAccount = false,
      String? identityProvider}) async {
    attempts.add(createAccount);
    providers.add(identityProvider);
    locales.add(locale);
    if (pending != null) return pending!.future;
    authenticated = succeeds;
    return succeeds;
  }
}

void main() {
  testWidgets(
      'long account prompts remain cancellable with large text in landscape',
      (tester) async {
    tester.view.physicalSize = const Size(600, 320);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final auth = _Auth();
    addTearDown(auth.dispose);
    await tester.pumpWidget(ChangeNotifierProvider<AuthService>.value(
      value: auth,
      child: wrapLocalized(Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                    onPressed: () {
                      final l10n = AppLocalizations.of(context);
                      showAccountRequiredDialog(context,
                          message:
                              '${l10n.liveTranscriptionAnonymousLimit}\n\n${l10n.accountStorySavedBeforeSignIn}');
                    },
                    child: const Text('Open'),
                  )))),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(auth.attempts, isEmpty);
  });
  for (final action in [
    'Cancel',
    'Continue with Google',
    'Sign in with email',
    'Create an account with email'
  ]) {
    testWidgets('$action has the expected account and action result',
        (tester) async {
      final auth = _Auth();
      bool? result;
      await tester.pumpWidget(ChangeNotifierProvider<AuthService>.value(
        value: auth,
        child: wrapLocalized(Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                      onPressed: () async =>
                          result = await showAccountRequiredDialog(context),
                      child: const Text('Sync'),
                    )))),
      ));
      await tester.tap(find.text('Sync'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Account required'), findsOneWidget);
      await tester.ensureVisible(find.text(action));
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      expect(result, action != 'Cancel');
      expect(
          auth.attempts,
          action == 'Cancel'
              ? isEmpty
              : [action == 'Create an account with email']);
      expect(
          auth.providers,
          action == 'Cancel'
              ? isEmpty
              : [action == 'Continue with Google' ? 'google' : '']);
      expect(auth.isAuthenticated, action != 'Cancel');
      auth.dispose();
    });
  }
  testWidgets(
      'failed draft preservation prevents sign-in and keeps the prompt open',
      (tester) async {
    final auth = _Auth();
    auth.succeeds = false;
    var saves = 0;
    var saveSucceeds = false;
    await tester.pumpWidget(ChangeNotifierProvider<AuthService>.value(
      value: auth,
      child: wrapLocalized(Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                    onPressed: () => showAccountRequiredDialog(context,
                        beforeSignIn: () async {
                      saves++;
                      return saveSucceeds;
                    }),
                    child: const Text('Open'),
                  )))),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Continue with Google'));
    await tester.tap(find.text('Continue with Google'));
    await tester.pumpAndSettle();
    expect(saves, 1);
    expect(auth.attempts, isEmpty);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('Could not save the story.'), findsOneWidget);
    saveSucceeds = true;
    await tester.ensureVisible(find.text('Continue with Google'));
    await tester.tap(find.text('Continue with Google'));
    await tester.pumpAndSettle();
    expect(saves, 2);
    expect(auth.attempts, [false]);
    expect(auth.providers, ['google']);
    await tester.ensureVisible(find.text('Create an account with email'));
    await tester.tap(find.text('Create an account with email'));
    await tester.pumpAndSettle();
    expect(saves, 2,
        reason: 'a prepared draft is not saved again on auth retries');
    expect(auth.attempts, [false, true]);
    expect(auth.providers, ['google', '']);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    auth.dispose();
  });
  for (final locale in ['en', 'de']) {
    testWidgets('$locale choices share busy and cooldown protection',
        (tester) async {
      final auth = _Auth()..pending = Completer<bool>();
      addTearDown(auth.dispose);
      final preparation = Completer<bool>();
      var saves = 0;
      await tester.pumpWidget(ChangeNotifierProvider<AuthService>.value(
        value: auth,
        child: wrapLocalized(
            Scaffold(
                body: Builder(
                    builder: (context) => TextButton(
                        onPressed: () => showAccountRequiredDialog(context,
                                beforeSignIn: () {
                              saves++;
                              return preparation.future;
                            }),
                        child: const Text('Open')))),
            locale: Locale(locale)),
      ));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final l10n =
          AppLocalizations.of(tester.element(find.byType(AlertDialog)));
      expect(find.text(l10n.loginGoogleHint), findsOneWidget);
      final google =
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed!;
      google();
      google();
      await tester.pump();
      expect(saves, 1);
      expect(auth.attempts, isEmpty,
          reason: 'Google must await draft preservation');
      expect(
          tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
          isNull);
      expect(
          tester
              .widget<TextButton>(
                  find.widgetWithText(TextButton, l10n.loginEmailCreateButton))
              .onPressed,
          isNull);
      preparation.complete(true);
      await tester.pump();
      expect(auth.providers, ['google']);
      expect(auth.locales, [locale]);
      auth.retrySeconds = 120;
      auth.pending!.complete(false);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull);
      expect(
          tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
          isNull);
      expect(
          tester
              .widget<TextButton>(
                  find.widgetWithText(TextButton, l10n.loginEmailCreateButton))
              .onPressed,
          isNull);
      await tester.tap(find.text(l10n.commonCancel));
      await tester.pumpAndSettle();
    });
  }
}
