import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/screens/events/add_event_screen.dart';
import 'package:relationship_manager/screens/quick_add/quick_add_sheet.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/recorder_controller.dart';
import 'package:relationship_manager/services/recording_file_store_native.dart';
import 'package:relationship_manager/services/transcription_client.dart';

import '../support/fake_audio_capture.dart';
import '../support/fake_speech_detector.dart';
import '../support/test_database.dart';

class _DelayedStopCapture extends FakeAudioCapture {
  final stopping = Completer<void>.sync();
  final finish = Completer<void>.sync();

  @override
  Future<void> stop() async {
    stopping.complete();
    await finish.future;
    await super.stop();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final quickAdd in [true, false]) {
    testWidgets(
        '${quickAdd ? 'Quick add' : 'Add event'} waits for audio before saving',
        (tester) async {
      final directory = Directory.systemTemp.createTempSync('recording_save');
      addTearDown(() => directory.deleteSync(recursive: true));
      final db = createTestDatabaseService();
      await tester.runAsync(db.initialize);
      final capture = _DelayedStopCapture();
      final recorder = RecorderController(
        createSpeechDetector: () async => EndingDetector(frames: 1000, minSpeechFrames: 1),
        audioCapture: capture,
        fileStore: NativeRecordingFileStore(baseDirectory: directory),
        database: db,
        transcriptionClient: TranscriptionClient(
          baseUrl: 'https://api.example.com',
          getToken: () => null,
          httpClient: MockClient((request) async => http.Response(
              request.method == 'GET' ? '{"remainingRecordings":10}' : '{"text":"Original words."}', 200)),
        ),
      );
      addTearDown(recorder.dispose);
      final position = ValueNotifier(const LatLng(10, 10));
      addTearDown(position.dispose);
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChangeNotifierProvider<DatabaseService>.value(
          value: db,
          child: Scaffold(
              body: quickAdd
                  ? QuickAddSheet(
                      position: position, recorderController: recorder)
                  : AddEventScreen(recorderController: recorder)),
        ),
      ));
      for (var frame = 0; frame < 2; frame++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      await tester.enterText(
          quickAdd
              ? find.widgetWithText(TextField, 'What happened here?')
              : find.byType(TextFormField).first,
          'A recorded story');
      await tester.runAsync(() async {
        await recorder.start();
        capture.emitChunk(Uint8List(3200));
      });
      await tester.pump();
      final save = quickAdd
          ? find.widgetWithText(FilledButton, 'Save story')
          : find.widgetWithText(TextButton, 'Save');
      VoidCallback? saveCallback() => quickAdd
          ? tester.widget<FilledButton>(save).onPressed
          : tester.widget<TextButton>(save).onPressed;

      expect(saveCallback(), isNull);

      // Invoke the actual screen stop handler while microphone shutdown is held.
      final Function stop = quickAdd
          ? tester
              .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.stop)).onPressed! as Function
          : tester
              .widget<IconButton>(
                  find.widgetWithIcon(IconButton, Icons.stop_circle))
              .onPressed! as Function;
      late Future<void> stopped;
      await tester.runAsync(() async {
        stopped = stop() as Future<void>;
        await capture.stopping.future;
      });
      await tester.pump();
      expect(recorder.state, RecorderState.finishing);
      final saveDuringFinishing = saveCallback();
      if (saveDuringFinishing != null) {
        await tester
            .runAsync(() async => await (saveDuringFinishing as Function)());
      }
      await tester.runAsync(() async {
        capture.finish.complete();
        await stopped;
      });
      await tester.pump();
      expect(saveDuringFinishing, isNull,
          reason:
              'saving before finalization silently loses the recording attachment');
      expect(saveCallback(), isNotNull);
      await tester.runAsync(() async => await (saveCallback()! as Function)());
      await tester.runAsync(() async {
        final event = (await db.getEvents()).single;
        expect(event.files, hasLength(1));
        expect(event.files.single.id, recorder.lastStopResult!.attachedFile.id);
        final reloaded = (await db.getEvent(event.id))!.files.single;
        expect(reloaded.transcriptSlices.single.text, 'Original words.');
        expect(reloaded.transcriptSlices.single.startByte, 0);
        expect(reloaded.transcriptSlices.single.endByte, 3200);
        final recording = await db.getLocalRecording(event.files.single.id);
        expect(recording!.eventId, event.id);
      });
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
