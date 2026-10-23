import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/services/auth_service.dart';
import 'package:relationship_manager/widgets/account_required_dialog.dart';

import '../support/localized_app.dart';

class _Auth extends AuthService {
  final attempts = <bool>[];
  bool authenticated = false;
  bool succeeds = true;
  @override
  bool get isAuthenticated => authenticated;
  @override
  Future<bool> signIn(
      {String locale = 'de', bool createAccount = false}) async {
    attempts.add(createAccount);
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
  for (final action in ['Cancel', 'Sign in', 'Create account']) {
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
      await tester.tap(
          action == 'Sign in' ? find.byType(FilledButton) : find.text(action));
      await tester.pumpAndSettle();
      expect(result, action != 'Cancel');
      expect(auth.attempts,
          action == 'Cancel' ? isEmpty : [action == 'Create account']);
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
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();
    expect(saves, 1);
    expect(auth.attempts, isEmpty);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('Could not save the story.'), findsOneWidget);
    saveSucceeds = true;
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();
    expect(saves, 2);
    expect(auth.attempts, [true]);
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(saves, 2,
        reason: 'a prepared draft is not saved again on auth retries');
    expect(auth.attempts, [true, false]);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    auth.dispose();
  });
}
