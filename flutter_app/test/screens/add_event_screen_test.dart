// Widget test for AddEventScreen's recording integration: the record
// button drives a RecorderController (fakes underneath - no real
// microphone/backend), the live transcript flows into the description
// field, and the recording is attached to the event on save.
//
// sqflite_common_ffi's isolate-based transaction lock doesn't resolve
// inside testWidgets' FakeAsync zone (see widget_test.dart), so every
// interaction that reaches the database is driven through
// tester.runAsync(). Buttons are invoked by calling their onPressed
// callback directly (still the exact widget code path) rather than via
// tester.tap(): tap()'s gesture-recognition pipeline doesn't reliably
// complete when combined with runAsync.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/screens/events/add_event_screen.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/recorder_controller.dart';
import 'package:relationship_manager/services/recording_file_store_native.dart';
import 'package:relationship_manager/services/transcription_client.dart';

import '../support/fake_audio_capture.dart';
import '../support/test_database.dart';

/// Invokes [finder]'s callback (an IconButton or TextButton's onPressed)
/// directly and, if it returns a Future, awaits it - all within the real
/// (non-FakeAsync) zone runAsync provides, since these callbacks reach the
/// database.
Future<void> _pressAsync(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    final widget = tester.widget(finder);
    final callback = (widget is IconButton ? widget.onPressed : (widget as TextButton).onPressed)!
        as Function;
    final dynamic maybeFuture = callback();
    if (maybeFuture is Future) {
      await maybeFuture;
    }
  });
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('add_event_screen_test');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  testWidgets(
      'records, shows the live transcript in the description, and attaches the recording on save',
      (tester) async {
    late DatabaseService db;
    await tester.runAsync(() async {
      db = createTestDatabaseService();
      await db.initialize();
    });

    final capture = FakeAudioCapture();
    final store = NativeRecordingFileStore(baseDirectory: tempDir);
    final client = TranscriptionClient(
      baseUrl: 'https://api.example.com',
      getToken: () => 'tok',
      httpClient: MockClient(
          (request) async => http.Response(jsonEncode({'text': 'said hello'}), 200)),
    );
    final controller = RecorderController(
      audioCapture: capture,
      fileStore: store,
      database: db,
      transcriptionClient: client,
      segmentDuration: const Duration(milliseconds: 100),
      backoff: (_) => Duration.zero,
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChangeNotifierProvider<DatabaseService>.value(
          value: db,
          child: AddEventScreen(recorderController: controller),
        ),
      ),
    );

    final micButton = find.byWidgetPredicate(
        (w) => w is IconButton && (w.icon as Icon).icon == Icons.mic);
    expect(micButton, findsOneWidget);

    // Tap the mic button to start recording (through the widget's own
    // _toggleRecording, which is what sets the pending recording on stop).
    await _pressAsync(tester, micButton);
    await tester.pump();

    expect(find.byIcon(Icons.stop_circle), findsOneWidget);

    // 16kHz mono 16-bit -> 100ms segment is exactly 3200 bytes. Appending
    // it, cutting the segment and transcribing it all involve real file
    // I/O and the database, so this needs runAsync too.
    await tester.runAsync(() async {
      capture.emitChunk(Uint8List(3200));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    final stopButton = find.byWidgetPredicate(
        (w) => w is IconButton && (w.icon as Icon).icon == Icons.stop_circle);
    await _pressAsync(tester, stopButton);
    // Let the transcription request (and the resulting description
    // update) fully settle before the next pump.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    expect(find.byIcon(Icons.mic), findsOneWidget); // back to idle
    // The live transcript should have flowed into the description field.
    expect(
      find.byWidgetPredicate((w) =>
          w is TextFormField &&
          w.controller?.text.contains('said hello') == true),
      findsOneWidget,
    );

    // Fill in the required title and save. Title is the first of the two
    // TextFormFields on this screen (the other is Description).
    final titleField = find.byType(TextFormField).first;
    await tester.enterText(titleField, "Grandma's story");
    await tester.pump();

    final saveButton = find.byType(TextButton);
    await _pressAsync(tester, saveButton);
    await tester.pump();

    late List<Event> events;
    await tester.runAsync(() async {
      events = await db.getEvents();
    });

    expect(events, hasLength(1));
    expect(events.first.title, "Grandma's story");
    expect(events.first.files, hasLength(1));
    expect(events.first.files.first.kind, AttachedFile.kindRecording);
    expect(events.first.description, contains('said hello'));

    late LocalRecordingState? recording;
    await tester.runAsync(() async {
      recording = await db.getLocalRecording(events.first.files.first.id);
    });
    expect(recording!.eventId, events.first.id);
  });
}
