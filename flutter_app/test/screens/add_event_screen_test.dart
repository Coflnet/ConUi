import 'package:relationship_manager/services/local_draft_store.dart';
import 'package:relationship_manager/widgets/unsaved_draft_guard.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
import 'package:relationship_manager/services/auth_service.dart';
import 'package:relationship_manager/services/recorder_controller.dart';
import 'package:relationship_manager/services/recording_file_store_native.dart';
import 'package:relationship_manager/services/transcription_client.dart';

import '../support/fake_audio_capture.dart';
import '../support/fake_speech_detector.dart';
import '../support/test_database.dart';
import '../support/account_prompt_auth.dart';

/// Invokes [finder]'s callback (an IconButton or TextButton's onPressed)
/// directly and, if it returns a Future, awaits it - all within the real
/// (non-FakeAsync) zone runAsync provides, since these callbacks reach the
/// database.
Future<void> _pressAsync(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, -150,
        scrollable: find.byType(Scrollable).first);
  }
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
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('add_event_screen_test');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  testWidgets('anonymous quota failure explains sign-in and retains the recording',
      (tester) async {
    final db = createTestDatabaseService();
    await tester.runAsync(db.initialize);
    final capture = FakeAudioCapture();
    final controller = RecorderController(
      createSpeechDetector: () async => EndingDetector(minSpeechFrames: 1),
      audioCapture: capture,
      fileStore: NativeRecordingFileStore(baseDirectory: tempDir),
      database: db,
      transcriptionClient: TranscriptionClient(
        baseUrl: 'https://api.example.com', getToken: () => null,
        httpClient: MockClient((request) async => request.method == 'GET'
            ? http.Response(jsonEncode({'available': true, 'remainingRecordings': 3}), 200)
            : http.Response(jsonEncode({'slug': 'anonymous_daily_limit', 'message': 'Sign in to record more.'}), 429))),
      maxSegmentRetries: 0,
    );
    addTearDown(controller.dispose);
    final auth = AccountPromptAuth();
    await tester.pumpWidget(ChangeNotifierProvider<AuthService>.value(value: auth, child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChangeNotifierProvider<DatabaseService>.value(
        value: db, child: AddEventScreen(recorderController: controller,
            initialParticipantIds: const ['chosen-person'])),
    )));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
        tester.element(find.byType(AddEventScreen)));
    expect(capture.isRecording, isFalse);
    expect(controller.state, RecorderState.idle);
    expect(find.text(l10n.storyAudioFirstTitle), findsOneWidget);
    expect(find.text(l10n.recordingGuestTranscriptionWarning), findsNothing);
    expect(find.text(l10n.loginAccountButton), findsNothing);
    expect(tester.getTopLeft(find.widgetWithIcon(IconButton, Icons.mic)).dy,
        lessThan(tester.getTopLeft(find.widgetWithText(TextFormField, 'Title *')).dy));
    final titleController = tester.widget<TextFormField>(find.widgetWithText(TextFormField, 'Title *')).controller!;
    await tester.scrollUntilVisible(find.widgetWithText(TextFormField, 'Description'), 150,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(find.widgetWithText(TextFormField, 'Description'), 'My unsaved notes.');
    expect(capture.isRecording, isFalse);
    await _pressAsync(tester, find.widgetWithIcon(IconButton, Icons.mic));
    await tester.pump();
    expect(find.text(l10n.recordingGuestTranscriptionWarning), findsNothing);
    await tester.runAsync(() async {
      capture.emitChunk(Uint8List(1600));
      await Future<void>.delayed(Duration.zero);
    });
    await _pressAsync(tester, find.widgetWithIcon(IconButton, Icons.stop_circle));
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining(l10n.liveTranscriptionAnonymousLimit), findsWidgets);
    expect(auth.choices, isEmpty);
    auth.beforeAttempt = () async {
      final saved = (await db.getEvents()).single;
      expect(saved.description, 'My unsaved notes.');
      expect(saved.title, 'My unsaved notes.');
      expect(saved.participantIds, ['chosen-person']);
      expect(saved.files.single.id, controller.lastStopResult!.attachedFile.id);
    };
    await tester.runAsync(() async {
      await (tester.widget<TextButton>(find.widgetWithText(TextButton, 'Create an account with email')).onPressed! as Function)();
    });
    await tester.pump();
    expect(auth.choices, [true]);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextFormField>(find.widgetWithText(TextFormField, 'Description')).controller!.text, 'My unsaved notes.');
    expect(titleController.text, 'My unsaved notes.');
    await tester.runAsync(() async {
      final file = controller.lastStopResult!.attachedFile;
      expect(await NativeRecordingFileStore(baseDirectory: tempDir).exists(file.id), isTrue);
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
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
      createSpeechDetector: () async => EndingDetector(minSpeechFrames: 1),
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
    await tester.pumpAndSettle();

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
    expect(tester.widget<TextFormField>(
        find.widgetWithText(TextFormField, 'Description')).controller!.text,
        contains('said hello'));

    // Edit the suggested title and save.
    final titleField = find.widgetWithText(TextFormField, 'Title *');
    await tester.enterText(titleField, "Grandma's story");
    await tester.pump();

    final saveButton = find.widgetWithText(TextButton, 'Save');
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

  testWidgets(
      'final recording tail adds detected people while preserving edited story notes and participants',
      (tester) async {
    final db = createTestDatabaseService();
    final manual = Person(id: 'manual', name: 'Alex Jones');
    final paul = Person(id: 'known-paul', name: 'Paul Roberts', aliases: ['Paul']);
    final original = Event(
      id: 'original-story',
      title: 'An existing story',
      description: 'Original typed notes.',
      dateTime: DateTime(1985, 5),
      datePrecision: DatePrecision.month,
      participantIds: [manual.id],
    );
    await tester.runAsync(() async {
      await db.initialize();
      await db.savePerson(manual);
      await db.savePerson(paul);
      await db.saveEvent(original);
    });
    addTearDown(() => tester.runAsync(() async {
          await (await db.database).close();
          db.dispose();
        }));

    const transcript = 'My sister Jane Smith visited Uncle Paul.';
    var transcriptionRequests = 0;
    final capture = FakeAudioCapture();
    final store = NativeRecordingFileStore(baseDirectory: tempDir);
    final recorder = RecorderController(
      createSpeechDetector: () async => EndingDetector(minSpeechFrames: 1),
      audioCapture: capture,
      fileStore: store,
      database: db,
      transcriptionClient: TranscriptionClient(
        baseUrl: 'https://api.example.com',
        getToken: () => 'tok',
        httpClient: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(jsonEncode({'available': true}), 200);
          }
          transcriptionRequests++;
          return http.Response(jsonEncode({'text': transcript}), 200);
        }),
      ),
      segmentDuration: const Duration(seconds: 30),
      backoff: (_) => Duration.zero,
    );
    addTearDown(recorder.dispose);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChangeNotifierProvider<DatabaseService>.value(
        value: db,
        child: AddEventScreen(existingEvent: original, recorderController: recorder),
      ),
    ));
    await tester.pumpAndSettle();

    await _pressAsync(tester, find.widgetWithIcon(IconButton, Icons.mic));
    await tester.pump();
    await tester.runAsync(() async {
      // This short buffer stays below the segmentation threshold. Its text
      // appears only when Stop flushes the final tail, never as a live segment.
      capture.emitChunk(Uint8List(1600));
      await Future<void>.delayed(Duration.zero);
    });
    expect(transcriptionRequests, 0);
    expect(recorder.liveTranscript, isEmpty);
    await _pressAsync(tester, find.widgetWithIcon(IconButton, Icons.stop_circle));
    await tester.pump();
    expect(transcriptionRequests, 1);
    await tester.scrollUntilVisible(find.widgetWithText(TextFormField, 'Description'), 150,
        scrollable: find.byType(Scrollable).first);
    expect(find.byWidgetPredicate((w) => w is TextFormField &&
        w.controller?.text == 'Original typed notes. $transcript'), findsOneWidget);
    final recordingFile = recorder.lastStopResult!.attachedFile;
    await tester.runAsync(() async {
      // Recognition creates only a draft; the original story is unchanged.
      expect((await db.getPersons()).map((p) => p.id), unorderedEquals([manual.id, paul.id]));
      expect((await db.getEvent(original.id))!.description, original.description);
    });

    await _pressAsync(tester, find.widgetWithText(TextButton, 'Save'));
    await tester.pump();
    await tester.runAsync(() async {
      final people = await db.getPersons();
      final jane = people.singleWhere((p) => p.name == 'Jane Smith');
      expect(people, hasLength(3));
      expect(people.where((p) => p.name == paul.name).single.id, paul.id);
      final saved = (await db.getEvent(original.id))!;
      expect(saved.title, original.title);
      expect(saved.dateTime, DateTime(1985, 5));
      expect(saved.datePrecision, DatePrecision.month);
      expect(saved.description, 'Original typed notes. $transcript');
      expect(saved.participantIds, unorderedEquals([manual.id, paul.id, jane.id]));
      expect(saved.files.single.kind, AttachedFile.kindRecording);
      expect(saved.files.single.id, recordingFile.id);
      expect(await store.exists(recordingFile.id), isTrue);
      expect((await db.getLocalRecording(recordingFile.id))!.eventId, original.id);
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('person information recording saves chained relationships and facts without a place',
      (tester) async {
    final db = createTestDatabaseService();
    final knownAlex = Person(id: 'known-alex', name: 'Alex');
    await tester.runAsync(() async {
      await db.initialize();
      await db.savePerson(knownAlex);
    });
    addTearDown(() => tester.runAsync(() async {
      await (await db.database).close();
      db.dispose();
    }));
    const transcript = 'Alex got a new car. Alex is the brother of Ben, '
        'who works at Zeta and is a colleague of Dana.';
    var transcriptionRequests = 0;
    final capture = FakeAudioCapture();
    final store = NativeRecordingFileStore(baseDirectory: tempDir);
    final recorder = RecorderController(
      createSpeechDetector: () async => EndingDetector(minSpeechFrames: 1),
      audioCapture: capture, fileStore: store, database: db,
      transcriptionClient: TranscriptionClient(
        baseUrl: 'https://api.example.com', getToken: () => 'tok',
        httpClient: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(jsonEncode({'available': true}), 200);
          }
          transcriptionRequests++;
          return http.Response(jsonEncode({'text': transcript}), 200);
        }),
      ),
      segmentDuration: const Duration(seconds: 30),
      backoff: (_) => Duration.zero,
    );
    addTearDown(recorder.dispose);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChangeNotifierProvider<DatabaseService>.value(
        value: db,
        child: AddEventScreen(
          initialTitle: 'Information about Alex',
          initialParticipantIds: [knownAlex.id],
          recorderController: recorder,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.widgetWithText(TextFormField, 'Description'), 150,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(find.widgetWithText(TextFormField, 'Description'), 'Typed notes.');
    await _pressAsync(tester, find.widgetWithIcon(IconButton, Icons.mic));
    await tester.pump();
    await tester.runAsync(() async {
      capture.emitChunk(Uint8List(1600));
      await Future<void>.delayed(Duration.zero);
    });
    expect(transcriptionRequests, 0);
    expect(recorder.liveTranscript, isEmpty);
    await _pressAsync(tester, find.widgetWithIcon(IconButton, Icons.stop_circle));
    await tester.pump();
    expect(transcriptionRequests, 1);
    await tester.scrollUntilVisible(find.widgetWithText(TextFormField, 'Description'), 150,
        scrollable: find.byType(Scrollable).first);
    expect(find.byWidgetPredicate((widget) => widget is TextFormField &&
        widget.controller?.text == 'Typed notes. $transcript'), findsOneWidget);
    final recordingFile = recorder.lastStopResult!.attachedFile;
    await tester.runAsync(() async {
      expect((await db.getPersons()).single.id, knownAlex.id);
      expect(await db.getEvents(), isEmpty);
      expect(await db.getConnections(), isEmpty);
    });
    await _pressAsync(tester, find.widgetWithText(TextButton, 'Save'));
    await tester.pump();
    await tester.runAsync(() async {
      final saved = (await db.getEvents()).single;
      final people = await db.getPersons();
      final alex = people.singleWhere((person) => person.name == 'Alex');
      final ben = people.singleWhere((person) => person.name == 'Ben');
      final dana = people.singleWhere((person) => person.name == 'Dana');
      expect(people, hasLength(3));
      expect(alex.id, knownAlex.id);
      expect(saved.title, 'Information about Alex');
      expect(saved.description, 'Typed notes. $transcript');
      expect(saved.placeId, isNull);
      expect(saved.participantIds, unorderedEquals([alex.id, ben.id, dana.id]));
      expect(ben.company, 'Zeta');
      expect(alex.storyFacts[saved.id], contains('Alex got a new car'));
      expect(ben.storyFacts[saved.id], contains('works at Zeta'));
      expect(dana.storyFacts, isEmpty);
      final connections = await db.getConnectionsForEvent(saved.id);
      expect(connections, hasLength(2));
      final siblings = connections.singleWhere((edge) => edge.relationshipType == 'sibling');
      expect({siblings.person1Id, siblings.person2Id}, {alex.id, ben.id});
      final colleagues = connections.singleWhere((edge) => edge.relationshipType == 'colleague');
      expect({colleagues.person1Id, colleagues.person2Id}, {ben.id, dana.id});
      for (final edge in connections) {
        expect(edge.isInferred, isTrue);
        expect(edge.sourceEventIds, [saved.id]);
      }
      expect(saved.files.single.id, recordingFile.id);
      expect(saved.files.single.kind, AttachedFile.kindRecording);
      expect(await store.exists(recordingFile.id), isTrue);
      expect((await db.getLocalRecording(recordingFile.id))!.eventId, saved.id);
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('saving an active recording draft restores text, people and original audio', (tester) async {
    final db = createTestDatabaseService();
    await tester.runAsync(db.initialize);
    final capture = FakeAudioCapture();
    final store = NativeRecordingFileStore(baseDirectory: tempDir);
    final recorder = RecorderController(
      createSpeechDetector: () async => EndingDetector(minSpeechFrames: 1),
      audioCapture: capture, fileStore: store, database: db,
      transcriptionClient: TranscriptionClient(baseUrl: 'https://api.example.com', getToken: () => 'tok',
        httpClient: MockClient((_) async => http.Response(jsonEncode({'text': 'Recorded memory.'}), 200))),
      backoff: (_) => Duration.zero,
    );
    addTearDown(recorder.dispose);
    Widget form() => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChangeNotifierProvider<DatabaseService>.value(value: db,
        child: AddEventScreen(recorderController: recorder, initialParticipantIds: const ['chosen-person'])),
    );
    await tester.pumpWidget(form());
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.widgetWithText(TextFormField, 'Description'), 150,
      scrollable: find.byType(Scrollable).first);
    await tester.enterText(find.widgetWithText(TextFormField, 'Description'), 'My typed memory.');
    await _pressAsync(tester, find.widgetWithIcon(IconButton, Icons.mic));
    await tester.runAsync(() async {
      capture.emitChunk(Uint8List(1600));
      await Future<void>.delayed(Duration.zero);
    });
    final guard = tester.state<UnsavedDraftGuardState>(find.byType(UnsavedDraftGuard));
    late Future<bool> close;
    await tester.runAsync(() async { close = guard.confirm(); });
    await tester.pump();
    expect(recorder.state, RecorderState.recording, reason: 'Keep editing must not stop capture');
    await tester.tap(find.text('Save draft'));
    await tester.runAsync(() async => expect(await close, isTrue));
    await tester.pump();
    expect(recorder.state, RecorderState.idle);
    final recordingId = recorder.lastStopResult!.attachedFile.id;
    final draft = await LocalDraftStore.read('story:new');
    expect((draft!['event'] as Map)['participantIds'], ['chosen-person']);
    expect((draft['recording'] as Map)['id'], recordingId);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(form());
    await tester.pumpAndSettle();
    expect(find.text('Saved draft restored'), findsOneWidget);
    await tester.scrollUntilVisible(find.widgetWithText(TextFormField, 'Description'), 150,
      scrollable: find.byType(Scrollable).first);
    expect(tester.widget<TextFormField>(find.widgetWithText(TextFormField, 'Description')).controller!.text,
      'My typed memory. Recorded memory.');
    await _pressAsync(tester, find.widgetWithText(TextButton, 'Save'));
    await tester.runAsync(() async {
      final event = (await db.getEvents()).single;
      expect(event.title, 'My typed memory. Recorded memory.');
      expect(event.participantIds, ['chosen-person']);
      expect(event.files.single.id, recordingId);
      expect((await db.getLocalRecording(recordingId))!.eventId, event.id);
      expect((await store.readBytes(recordingId)).sublist(44), Uint8List(1600));
    });
    expect(await LocalDraftStore.read('story:new'), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cancelling precision picker preserves displayed and saved precision', (tester) async {
    final db = createTestDatabaseService();
    final original = Event(title: 'Exact memory', dateTime: DateTime(1985, 4, 9, 17, 25));
    await tester.runAsync(() async { await db.initialize(); await db.saveEvent(original); });
    final recorder = RecorderController(createSpeechDetector: () async => null,
      audioCapture: FakeAudioCapture(), fileStore: NativeRecordingFileStore(baseDirectory: tempDir),
      database: db, transcriptionClient: TranscriptionClient(baseUrl: 'https://example.invalid', getToken: () => null));
    addTearDown(recorder.dispose);
    await tester.pumpWidget(MaterialApp(localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      initialRoute: '/editor', routes: {
        '/': (_) => const Scaffold(),
        '/editor': (_) => ChangeNotifierProvider<DatabaseService>.value(value: db,
          child: AddEventScreen(existingEvent: original, recorderController: recorder)),
      }));
    await tester.pumpAndSettle();
    final field = find.byType(DropdownButton<DatePrecision>);
    await Scrollable.ensureVisible(tester.element(field), alignment: 0.3);
    await tester.pumpAndSettle();
    await tester.tap(field);
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(AddEventScreen)));
    await tester.tap(find.text(l10n.quickAddAYear).last);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.widget<DropdownButton<DatePrecision>>(field).value, DatePrecision.time);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(DatePickerDialog), findsNothing);
    await _pressAsync(tester, find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final saved = (await db.getEvents()).single;
      expect(saved.dateTime, original.dateTime);
      expect(saved.datePrecision, DatePrecision.time);
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });

}
