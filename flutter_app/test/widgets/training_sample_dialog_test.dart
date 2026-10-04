import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:relationship_manager/services/auth_service.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/training_sample_client.dart';
import 'package:relationship_manager/widgets/training_sample_dialog.dart';

import '../support/training_sample_fakes.dart';

class _StoryDatabase extends DatabaseService {
  @override
  Future<List<Person>> getPersons({bool includeDeleted = false}) async => [
        Person(
            id: 'james',
            name: 'James',
            email: 'secret@example.invalid',
            storyFacts: {
              'story': 'James works at Google',
              'other': 'private-fact'
            }),
        Person(id: 'paul', name: 'Paul'),
      ];
  @override
  Future<List<Connection>> getConnectionsForEvent(String eventId) async => [
        Connection(
            person1Id: 'james',
            person2Id: 'paul',
            relationshipType: 'sibling',
            sourceEventIds: [eventId]),
      ];
}

class _PendingHttp extends CaptureTrainingHttp {
  final gate = Completer<void>();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await gate.future;
    return super.send(request);
  }
}

void main() {
  Future<void> open(WidgetTester tester, CaptureTrainingHttp httpClient,
      {Locale locale = const Locale('en'), ReportRecordingStore? store}) async {
    await tester.pumpWidget(MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
            builder: (context) => Scaffold(
                    body: TextButton(
                  child: const Text('Open report'),
                  onPressed: () => showDialog<void>(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => TrainingSampleDialog(
                          event: Event(
                              id: 'story',
                              title: 'Local story',
                              description:
                                  'Typed notes. James is the brother of Paul. James works at Google.',
                              dateTime: DateTime(2020),
                              participantIds: [
                                'james'
                              ]),
                          file: AttachedFile(
                              id: 'recording',
                              fileName: 'private-owner-name.wav',
                              filePath: 'recording',
                              mimeType: 'audio/wav',
                              size: 48,
                              kind: AttachedFile.kindRecording),
                          store: store ?? ReportRecordingStore(),
                          db: _StoryDatabase(),
                          client: TrainingSampleClient(
                              baseUrl: 'https://example.invalid',
                              getToken: () => null,
                              httpClient: httpClient),
                          language: 'en')),
                )))));
    await tester.tap(find.text('Open report'));
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String key) async {
    final finder = find.byKey(Key(key));
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('recording entry leaves uncaptured language unknown',
      (tester) async {
    await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthService>(create: (_) => AuthService()),
          ChangeNotifierProvider<DatabaseService>(
              create: (_) => _StoryDatabase()),
        ],
        child: MaterialApp(
          locale: const Locale('de'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
              body: TrainingSampleButton(
            event: Event(
                id: 'story',
                title: 'Restored English story',
                description: 'James is the brother of Paul.',
                dateTime: DateTime(2020)),
            file: AttachedFile(
                id: 'restored',
                fileName: 'restored.wav',
                filePath: 'restored',
                mimeType: 'audio/wav',
                size: 48,
                kind: AttachedFile.kindRecording),
            store: ReportRecordingStore(),
          )),
        )));
    await tester.tap(find.byKey(const ValueKey('training-report-restored')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
        tester
            .widget<TrainingSampleDialog>(find.byType(TrainingSampleDialog))
            .language,
        isNull);
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
  });

  testWidgets('preview is private and opening/cancelling sends nothing',
      (tester) async {
    final httpClient = CaptureTrainingHttp();
    await open(tester, httpClient);
    expect(
        find.text(
            'Typed notes. James is the brother of Paul. James works at Google.'),
        findsOneWidget);
    expect(find.text('James\nGoogle\nJames works at Google'), findsOneWidget);
    expect(find.textContaining('secret@example.invalid'), findsNothing);
    expect(find.textContaining('private-fact'), findsNothing);
    expect(
        tester
            .widget<CheckboxListTile>(find.byKey(const Key('training-consent')))
            .value,
        false);
    expect(
        tester
            .widget<CheckboxListTile>(find.byKey(const Key('training-audio')))
            .value,
        true);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('training-submit')))
            .onPressed,
        isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(httpClient.calls, 0);
  });

  testWidgets(
      'failure preserves correction and choices; retry keeps sample identity',
      (tester) async {
    final httpClient = CaptureTrainingHttp()..status = 503;
    final store = ReportRecordingStore()..present = false;
    await open(tester, httpClient, store: store);
    await tester.enterText(find.byKey(const Key('training-correction')),
        'They are siblings, not colleagues.');
    await choose(tester, 'training-audio');
    await choose(tester, 'training-consent');
    await tester.tap(find.byKey(const Key('training-submit')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Reporting is currently unavailable'),
        findsOneWidget);
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('training-correction')))
            .controller!
            .text,
        'They are siblings, not colleagues.');
    expect(
        tester
            .widget<CheckboxListTile>(find.byKey(const Key('training-audio')))
            .value,
        false);
    expect(
        tester
            .widget<CheckboxListTile>(find.byKey(const Key('training-consent')))
            .value,
        true);
    final first = jsonDecode(httpClient.request!.fields['metadata']!) as Map;
    expect(first['consent'], true);
    expect(httpClient.request!.files, isEmpty);
    httpClient.status = 201;
    await tester.tap(find.byKey(const Key('training-submit')));
    await tester.pumpAndSettle();
    final second = jsonDecode(httpClient.request!.fields['metadata']!) as Map;
    expect(second, first);
    expect(find.text('Sample received: ${first['sampleId']}'), findsOneWidget);
    expect(find.byKey(const Key('training-correction')), findsNothing);
    expect(find.textContaining('private-owner-name'), findsNothing);
    expect(store.streamReads, 0);
  });

  testWidgets('upload disables repeat submission and draft edits',
      (tester) async {
    final httpClient = _PendingHttp();
    await open(tester, httpClient);
    await choose(tester, 'training-consent');
    await tester.tap(find.byKey(const Key('training-submit')));
    await tester.pump();
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('training-submit')))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('training-correction')))
            .enabled,
        false);
    expect(
        tester
            .widget<CheckboxListTile>(find.byKey(const Key('training-audio')))
            .onChanged,
        isNull);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
            .onPressed,
        isNull);
    httpClient.gate.complete();
    await tester.pumpAndSettle();
    expect(httpClient.calls, 1);
    expect(find.textContaining('Sample received:'), findsOneWidget);
  });

  testWidgets('German expired sign-in guidance retains the editable draft',
      (tester) async {
    final httpClient = CaptureTrainingHttp()
      ..status = 401
      ..responseBody = '{"message":"raw-private-error"}';
    await open(tester, httpClient, locale: const Locale('de'));
    await tester.enterText(
        find.byKey(const Key('training-correction')), 'Korrektur');
    await choose(tester, 'training-consent');
    await tester.tap(find.byKey(const Key('training-submit')));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('Deine Anmeldung ist abgelaufen'), findsOneWidget);
    expect(find.textContaining('raw-private-error'), findsNothing);
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('training-correction')))
            .controller!
            .text,
        'Korrektur');
  });
}
