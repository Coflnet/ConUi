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
import 'package:shared_preferences/shared_preferences.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/screens/events/add_event_screen.dart';
import 'package:relationship_manager/screens/quick_add/quick_add_sheet.dart';
import 'package:relationship_manager/services/auth_service.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/local_draft_store.dart';
import 'package:relationship_manager/services/recorder_controller.dart';
import 'package:relationship_manager/services/recording_file_store_native.dart';
import 'package:relationship_manager/services/transcription_client.dart';

import '../support/account_prompt_auth.dart';
import '../support/fake_audio_capture.dart';
import '../support/fake_speech_detector.dart';
import '../support/test_database.dart';

class _EditorPopObserver extends NavigatorObserver {
  final Completer<void> closed;
  _EditorPopObserver(this.closed);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route.settings.name == 'editor') closed.complete();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final quick in [false, true]) {
    for (final saveDraft in [true, false]) {
      testWidgets(
          '${quick ? 'QuickAdd' : 'Story'} ${saveDraft ? 'draft save' : 'discard'} closes editor when final transcription hits quota',
          (tester) async {
        final db = createTestDatabaseService();
        await tester.runAsync(db.initialize);
        final directory =
            Directory.systemTemp.createTempSync('con-draft-quota');
        addTearDown(() => directory.deleteSync(recursive: true));
        final store = NativeRecordingFileStore(baseDirectory: directory);
        final capture = FakeAudioCapture();
        final recorder = RecorderController(
            createSpeechDetector: () async =>
                EndingDetector(minSpeechFrames: 1),
            audioCapture: capture,
            fileStore: store,
            database: db,
            maxSegmentRetries: 0,
            transcriptionClient: TranscriptionClient(
                baseUrl: 'https://example.invalid',
                getToken: () => null,
                httpClient: MockClient((request) async =>
                    request.method == 'GET'
                        ? http.Response(
                            jsonEncode(
                                {'available': true, 'remainingRecordings': 3}),
                            200)
                        : http.Response(
                            jsonEncode({
                              'slug': 'anonymous_daily_limit',
                              'message': 'Sign in'
                            }),
                            429))));
        addTearDown(recorder.dispose);
        late Completer<void> closed;
        late Completer<void> stopped;
        await tester.runAsync(() async {
          closed = Completer<void>();
          stopped = Completer<void>();
        });
        recorder.addListener(() {
          if (recorder.state == RecorderState.idle &&
              recorder.lastStopResult != null &&
              !stopped.isCompleted) {
            stopped.complete();
          }
        });
        final position = ValueNotifier(const LatLng(10, 10));
        addTearDown(position.dispose);
        final home = Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    child: const Text('Compose'),
                    onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            settings: const RouteSettings(name: 'editor'),
                            builder: (_) => Scaffold(
                                body: quick
                                    ? QuickAddSheet(
                                        position: position,
                                        recorderController: recorder)
                                    : AddEventScreen(
                                        recorderController: recorder)))))));
        await tester.pumpWidget(MultiProvider(
            providers: [
              ChangeNotifierProvider<DatabaseService>.value(value: db),
              ChangeNotifierProvider<AuthService>.value(
                  value: AccountPromptAuth()),
            ],
            child: MaterialApp(
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                navigatorObservers: [_EditorPopObserver(closed)],
                home: home)));
        await tester.tap(find.text('Compose'));
        await tester.pump();
        for (var frame = 0; frame < 2; frame++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 50)));
          await tester.pump();
        }
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await recorder.start();
          capture.emitChunk(Uint8List(1600));
          await Future<void>.delayed(Duration.zero);
        });
        await tester.pump();
        // Enter the back callback in the real zone, so its stop can await SQLite.
        await tester.runAsync(() async => tester.binding.handlePopRoute());
        await tester.pumpAndSettle();
        expect(find.text('Keep your changes?'), findsOneWidget);
        final save = saveDraft
            ? tester
                .widget<FilledButton>(
                    find.widgetWithText(FilledButton, 'Save draft'))
                .onPressed!
            : tester
                .widget<TextButton>(find.widgetWithText(TextButton, 'Discard'))
                .onPressed!;
        await tester.runAsync(() async {
          save();
          await stopped.future.timeout(const Duration(seconds: 5));
        });
        await tester.pumpAndSettle();
        expect(closed.isCompleted, isTrue,
            reason:
                'the editor must close, not an automatically opened account dialog');
        expect(find.text('Compose'), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        expect(recorder.lastStopResult!.failedSegments, isNotEmpty);
        final draft =
            await LocalDraftStore.read(quick ? 'quick-story:new' : 'story:new');
        final recordingId = recorder.lastStopResult!.attachedFile.id;
        if (saveDraft) {
          expect((draft!['recording'] as Map)['id'], recordingId);
          expect(draft['failedTranscription'], isTrue);
        } else {
          expect(draft, isNull);
        }
        await tester.runAsync(() async => expect(
            (await store.readBytes(recordingId)).sublist(44), Uint8List(1600)));
      });
    }
  }
}
