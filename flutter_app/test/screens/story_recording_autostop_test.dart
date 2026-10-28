import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/screens/events/add_event_screen.dart';
import 'package:relationship_manager/screens/quick_add/quick_add_sheet.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/recorder_controller.dart';
import 'package:relationship_manager/services/recording_file_store_native.dart';
import 'package:relationship_manager/services/transcription_client.dart';
import '../support/fake_audio_capture.dart';
import '../support/fake_speech_detector.dart';
import '../support/test_database.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final quick in [true, false]) {
    testWidgets(
        '${quick ? 'Quick add' : 'Story form'} shows transcription progress until the final response',
        (tester) async {
      final directory = Directory.systemTemp.createTempSync('con-progress-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final db = createTestDatabaseService();
      await tester.runAsync(db.initialize);
      final capture = FakeAudioCapture();
      late Completer<http.Response> response;
      late Completer<void> requested;
      await tester.runAsync(() async {
        response = Completer<http.Response>();
        requested = Completer<void>();
      });
      final recorder = RecorderController(
        createSpeechDetector: () async => EndingDetector(minSpeechFrames: 1),
        audioCapture: capture,
        fileStore: NativeRecordingFileStore(baseDirectory: directory),
        database: db,
        segmentDuration: const Duration(milliseconds: 100),
        transcriptionClient: TranscriptionClient(
          baseUrl: 'https://example.invalid',
          getToken: () => 'token',
          httpClient: MockClient((request) {
            if (request.method == 'GET') {
              return Future.value(http.Response(jsonEncode({'available': true,
                  'usedSeconds': 0, 'remainingSeconds': 1200, 'dailyLimitSeconds': 1200, 'resetAt': '2026-10-29T00:00:00Z'}), 200));
            }
            if (!requested.isCompleted) requested.complete();
            return response.future;
          }),
        ),
      );
      addTearDown(recorder.dispose);
      final position = ValueNotifier(const LatLng(10, 10));
      addTearDown(position.dispose);
      await tester.pumpWidget(ChangeNotifierProvider<DatabaseService>.value(
          value: db,
          child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                  body: quick
                      ? QuickAddSheet(
                          position: position, recorderController: recorder)
                      : AddEventScreen(recorderController: recorder)))));
      for (var frame = 0; frame < 2; frame++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      await tester.runAsync(recorder.start);
      await tester.pump();
      final l10n =
          AppLocalizations.of(tester.element(find.byType(Scaffold).first));
      expect(find.text(l10n.quickAddTranscribing), findsNothing);
      await tester.runAsync(() async {
        capture.emitChunk(Uint8List(3200));
        await requested.future.timeout(const Duration(seconds: 5));
      });
      await tester.pump();
      expect(find.text(l10n.quickAddTranscribing), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      late Future<RecorderStopResult> stopped;
      await tester.runAsync(() async {
        stopped = recorder.stop();
      });
      await tester.pump();
      expect(recorder.state, RecorderState.finishing);
      expect(find.text(l10n.quickAddTranscribing), findsOneWidget);
      if (quick) {
        expect(
            tester
                .widget<FilledButton>(
                    find.widgetWithText(FilledButton, 'Save story'))
                .onPressed,
            isNull);
      } else {
        expect(
            tester
                .widget<TextButton>(find.widgetWithText(TextButton, 'Save'))
                .onPressed,
            isNull);
      }
      await tester.runAsync(() async {
        response.complete(
            http.Response(jsonEncode({'text': 'Spoken story.'}), 200));
        await stopped.timeout(const Duration(seconds: 5));
      });
      await tester.pump();
      expect(find.text(l10n.quickAddTranscribing), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(recorder.lastStopResult!.transcript, contains('Spoken story.'));
      if (!quick)
        await tester.scrollUntilVisible(
            find.widgetWithText(TextFormField, 'Description'), 150,
            scrollable: find.byType(Scrollable).first);
      final controller = quick
          ? tester
              .widget<TextField>(
                  find.widgetWithText(TextField, 'What happened here?'))
              .controller!
          : tester
              .widget<TextFormField>(
                  find.widgetWithText(TextFormField, 'Description'))
              .controller!;
      expect(controller.text, recorder.lastStopResult!.transcript);
      await tester.pumpWidget(const SizedBox.shrink());
    });
    testWidgets(
        '${quick ? 'Quick add' : 'Story form'} keeps audio and notes after automatic stop',
        (tester) async {
      final directory = Directory.systemTemp.createTempSync('con-autostop-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final db = createTestDatabaseService();
      await tester.runAsync(db.initialize);
      final capture = FakeAudioCapture();
      final store = NativeRecordingFileStore(baseDirectory: directory);
      final recorder = RecorderController(
          createSpeechDetector: () async => EndingDetector(minSpeechFrames: 1),
          audioCapture: capture,
          fileStore: store,
          database: db,
          segmentDuration: const Duration(milliseconds: 100),
          transcriptionClient: TranscriptionClient(
              baseUrl: 'https://example.invalid',
              getToken: () => null,
              httpClient: MockClient((request) async => http.Response(
                  jsonEncode(request.method == 'GET'
                      ? {'available': true, 'usedSeconds': 299, 'remainingSeconds': 1, 'dailyLimitSeconds': 300, 'resetAt': '2026-10-29T00:00:00Z'}
                      : {'text': 'Spoken story.', 'usedSeconds': 300, 'remainingSeconds': 0, 'dailyLimitSeconds': 300, 'resetAt': '2026-10-29T00:00:00Z'}),
                  200))));
      addTearDown(recorder.dispose);
      final position = ValueNotifier(const LatLng(10, 10));
      addTearDown(position.dispose);
      await tester.pumpWidget(ChangeNotifierProvider<DatabaseService>.value(
          value: db,
          child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                  body: quick
                      ? QuickAddSheet(
                          position: position, recorderController: recorder)
                      : AddEventScreen(recorderController: recorder)))));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      if (quick) {
        await tester.enterText(
            find.widgetWithText(TextField, 'What happened here?'), 'My notes.');
      } else {
        await tester.enterText(
            find.widgetWithText(TextFormField, 'Title *'), 'Auto-stopped story');
        await tester.scrollUntilVisible(
            find.widgetWithText(TextFormField, 'Description'), 150,
            scrollable: find.byType(Scrollable).first);
        await tester.enterText(
            find.widgetWithText(TextFormField, 'Description'), 'My notes.');
      }
      final mic = find.widgetWithIcon(IconButton, Icons.mic);
      if (mic.evaluate().isEmpty) {
        await tester.scrollUntilVisible(mic, -150,
            scrollable: find.byType(Scrollable).first);
      }
      await tester.runAsync(() async {
        final stopped = Completer<void>();
        void completed() {
          if (recorder.lastStopResult != null && !stopped.isCompleted) stopped.complete();
        }
        recorder.addListener(completed);
        try {
          final start = tester.widget<IconButton>(mic).onPressed! as Function;
          await start();
          capture.emitChunk(Uint8List(3200));
          await stopped.future.timeout(const Duration(seconds: 5));
        } finally {
          recorder.removeListener(completed);
        }
      });
      await tester.pump();
      final l10n =
          AppLocalizations.of(tester.element(find.byType(Scaffold).first));
      expect(find.text(l10n.liveTranscriptionAnonymousLimit), findsOneWidget);
      expect(recorder.lastStopResult!.stopReason, StopReason.anonymousLimit);
      expect(capture.isRecording, isFalse);
      await tester.runAsync(() async {
        final Function save = quick
            ? tester
                .widget<FilledButton>(
                    find.widgetWithText(FilledButton, 'Save story'))
                .onPressed! as Function
            : tester
                .widget<TextButton>(find.widgetWithText(TextButton, 'Save'))
                .onPressed! as Function;
        await save();
        final story = (await db.getEvents()).single;
        expect(story.description, 'My notes. Spoken story.');
        expect(story.files.single.kind, AttachedFile.kindRecording);
        expect(await store.exists(story.files.single.id), isTrue);
        expect((await store.readBytes(story.files.single.id)).sublist(44), Uint8List(3200));
        expect((await db.getLocalRecording(story.files.single.id))!.eventId,
            story.id);
      });
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
