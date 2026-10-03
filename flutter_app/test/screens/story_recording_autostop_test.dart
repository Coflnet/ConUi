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
import '../support/test_database.dart';

void main() {
  for (final quick in [true, false]) {
    testWidgets('${quick ? 'Quick add' : 'Story form'} keeps audio and notes after automatic stop', (tester) async {
      final directory = Directory.systemTemp.createTempSync('con-autostop-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final db = createTestDatabaseService();
      await tester.runAsync(db.initialize);
      final capture = FakeAudioCapture();
      final store = NativeRecordingFileStore(baseDirectory: directory);
      final recorder = RecorderController(audioCapture: capture, fileStore: store,
          database: db, transcriptionClient: TranscriptionClient(
            baseUrl: 'https://example.invalid', getToken: () => null,
            httpClient: MockClient((request) async => http.Response(jsonEncode(
              request.method == 'GET' ? {'remainingRecordings': 3} : {'text': 'Spoken story.'}), 200))));
      addTearDown(recorder.dispose);
      final position = ValueNotifier(const LatLng(10, 10));
      addTearDown(position.dispose);
      await tester.pumpWidget(ChangeNotifierProvider<DatabaseService>.value(value: db,
        child: MaterialApp(localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: quick ? QuickAddSheet(position: position, recorderController: recorder)
              : AddEventScreen(recorderController: recorder)))));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      if (quick) {
        await tester.enterText(find.widgetWithText(TextField, 'What happened here?'), 'My notes.');
      } else {
        await tester.enterText(find.byType(TextFormField).first, 'Auto-stopped story');
        await tester.enterText(find.byType(TextFormField).last, 'My notes.');
      }
      await tester.runAsync(() async {
        final Function start = quick
            ? tester.widget<GestureDetector>(find.descendant(of: find.bySemanticsLabel('Start recording'), matching: find.byType(GestureDetector))).onTap! as Function
            : tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.mic)).onPressed! as Function;
        await start();
        capture.emitChunk(Uint8List(1600));
        await Future<void>.delayed(Duration.zero);
        await recorder.stop(reason: StopReason.anonymousLimit);
      });
      await tester.pump();
      final l10n = AppLocalizations.of(tester.element(find.byType(Scaffold).first));
      expect(find.text(l10n.recordingAnonymousStopped), findsOneWidget);
      await tester.runAsync(() async {
        final Function save = quick
            ? tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save story')).onPressed! as Function
            : tester.widget<TextButton>(find.widgetWithText(TextButton, 'Save')).onPressed! as Function;
        await save();
        final story = (await db.getEvents()).single;
        expect(story.description, 'My notes. Spoken story.');
        expect(story.files.single.kind, AttachedFile.kindRecording);
        expect(await store.exists(story.files.single.id), isTrue);
        expect((await db.getLocalRecording(story.files.single.id))!.eventId, story.id);
      });
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
