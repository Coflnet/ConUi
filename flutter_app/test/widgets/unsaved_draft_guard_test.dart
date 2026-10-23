import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/services/local_draft_store.dart';
import 'package:relationship_manager/widgets/story_date_picker.dart';
import 'package:relationship_manager/widgets/unsaved_draft_guard.dart';
import 'package:relationship_manager/models/models.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('back offers keeping edits, then saves an explicit local draft',
      (tester) async {
    final text = TextEditingController();
    addTearDown(text.dispose);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
          builder: (context) => Scaffold(
                  body: TextButton(
                child: const Text('Open'),
                onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => UnsavedDraftGuard(
                              isDirty: () => text.text.isNotEmpty,
                              onSaveDraft: () async {
                                await LocalDraftStore.write(
                                    'test', {'text': text.text});
                                return true;
                              },
                              onDiscard: () => LocalDraftStore.remove('test'),
                              child: Scaffold(
                                  appBar: AppBar(title: const Text('Edit')),
                                  body: TextField(controller: text)),
                            ))),
              ))),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'A memory to finish');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('A memory to finish'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save draft'));
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    expect(await LocalDraftStore.read('test'), {'text': 'A memory to finish'});
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('unrelated', 'keep');
    await LocalDraftStore.clearAll();
    expect(await LocalDraftStore.read('test'), isNull);
    expect(prefs.getString('unrelated'), 'keep');
  });

  testWidgets('failed draft write keeps the form and allows retry',
      (tester) async {
    final key = GlobalKey<UnsavedDraftGuardState>();
    var attempts = 0;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
          body: UnsavedDraftGuard(
              key: key,
              isDirty: () => true,
              onSaveDraft: () async {
                if (++attempts == 1) throw StateError('storage unavailable');
                return true;
              },
              onDiscard: () async {},
              child: const Text('Still editing'))),
    ));
    var close = key.currentState!.confirm();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save draft'));
    await tester.pumpAndSettle();
    expect(await close, isFalse);
    expect(find.text('Still editing'), findsOneWidget);
    close = key.currentState!.confirm();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save draft'));
    await tester.pumpAndSettle();
    expect(await close, isTrue);
  });

  testWidgets('partial historical date validates the year and preserves month',
      (tester) async {
    DateTime? result;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () async => result = await pickStoryDate(
                      context, DateTime(1985, 4, 9), DatePrecision.month),
                  child: const Text('Date')))),
    ));
    await tester.tap(find.text('Date'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '0');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a year from 1 to 2100.'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '1965');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(result, DateTime(1965, 4));
  });
}
