// Widget tests for QuickAddSheet: the save rules (text-or-recording
// required, person creation, nearby place proposal/reuse), live transcript
// text never overwriting what the user typed, and the unsaved-content
// confirmation before the sheet is dismissed.
//
// Follows the pattern documented in add_event_screen_test.dart: sqflite_ffi's
// isolate-based transaction lock needs tester.runAsync() for anything that
// touches the database, and buttons are invoked via their onPressed callback
// directly rather than tester.tap() so they work reliably inside runAsync.
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
import 'package:relationship_manager/screens/quick_add/quick_add_sheet.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/recorder_controller.dart';
import 'package:relationship_manager/services/recording_file_store_native.dart';
import 'package:relationship_manager/services/transcription_client.dart';

import '../../support/fake_audio_capture.dart';
import '../../support/test_database.dart';

// The various onPressed callbacks are statically typed as VoidCallback
// (void Function()), but the actual closures passed in are async and
// really return a Future at runtime. Casting to the untyped `Function`
// before calling makes the call site dynamically dispatched, so the real
// runtime return value (the Future) is captured instead of being coerced
// to void - the same trick add_event_screen_test.dart's _pressAsync uses.
Future<void> _pressAsync(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    final widget = tester.widget(finder);
    final Function callback;
    if (widget is FilledButton) {
      callback = widget.onPressed! as Function;
    } else if (widget is TextButton) {
      callback = widget.onPressed! as Function;
    } else if (widget is ActionChip) {
      callback = widget.onPressed! as Function;
    } else if (widget is ChoiceChip) {
      callback = () => widget.onSelected!(true);
    } else {
      throw StateError('_pressAsync: unsupported widget type ${widget.runtimeType}');
    }
    final dynamic maybeFuture = callback();
    if (maybeFuture is Future) await maybeFuture;
  });
}

RecorderController _buildRecorder({
  required FakeAudioCapture capture,
  required DatabaseService db,
  required Directory tempDir,
  String transcribedText = 'said hello',
}) {
  return RecorderController(
    audioCapture: capture,
    fileStore: NativeRecordingFileStore(baseDirectory: tempDir),
    database: db,
    transcriptionClient: TranscriptionClient(
      baseUrl: 'https://api.example.com',
      getToken: () => 'tok',
      httpClient: MockClient(
          (request) async => http.Response(jsonEncode({'text': transcribedText}), 200)),
    ),
    segmentDuration: const Duration(milliseconds: 100),
    backoff: (_) => Duration.zero,
  );
}

Widget _wrap(DatabaseService db, Widget child) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: ChangeNotifierProvider<DatabaseService>.value(
      value: db,
      child: Scaffold(body: child),
    ),
  );
}

// Two rounds: the sheet's _loadLookups() runs from a post-frame callback
// and itself awaits real DB I/O (db.getPersons()/getPlaces()), so it needs
// one settle to let the callback fire and start the I/O, then another to
// let the resulting setState's rebuild land - one round alone is flaky.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 2; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('quick_add_sheet_test');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('save rules', () {
    testWidgets('blocks save with neither text nor a recording', (tester) async {
      late DatabaseService db;
      await tester.runAsync(() async {
        db = createTestDatabaseService();
        await db.initialize();
      });
      final capture = FakeAudioCapture();
      final recorder = _buildRecorder(capture: capture, db: db, tempDir: tempDir);
      final position = ValueNotifier<LatLng>(const LatLng(10, 10));

      await tester.pumpWidget(_wrap(
          db, QuickAddSheet(position: position, recorderController: recorder)));
      await _settle(tester);

      await _pressAsync(tester, find.widgetWithText(FilledButton, 'Save story'));
      await tester.pump();

      expect(find.text('Add some text or record something first.'), findsOneWidget);
      late List<Event> events;
      await tester.runAsync(() async => events = await db.getEvents());
      expect(events, isEmpty);
    });

    testWidgets('typed text without any recording is a valid story', (tester) async {
      late DatabaseService db;
      await tester.runAsync(() async {
        db = createTestDatabaseService();
        await db.initialize();
      });
      final capture = FakeAudioCapture();
      final recorder = _buildRecorder(capture: capture, db: db, tempDir: tempDir);
      final position = ValueNotifier<LatLng>(const LatLng(10, 10));

      await tester.pumpWidget(_wrap(
          db, QuickAddSheet(position: position, recorderController: recorder)));
      await _settle(tester);

      await tester.enterText(
          find.widgetWithText(TextField, 'What happened here?'), 'We had a picnic here.');
      await tester.pump();

      await _pressAsync(tester, find.widgetWithText(FilledButton, 'Save story'));
      await _settle(tester);

      late List<Event> events;
      await tester.runAsync(() async => events = await db.getEvents());
      expect(events, hasLength(1));
      expect(events.first.description, 'We had a picnic here.');
      expect(events.first.files, isEmpty);
    });
  });

  group('persons', () {
    testWidgets('typing a new name and confirming creates the person on save',
        (tester) async {
      late DatabaseService db;
      await tester.runAsync(() async {
        db = createTestDatabaseService();
        await db.initialize();
      });
      final capture = FakeAudioCapture();
      final recorder = _buildRecorder(capture: capture, db: db, tempDir: tempDir);
      final position = ValueNotifier<LatLng>(const LatLng(10, 10));

      await tester.pumpWidget(_wrap(
          db, QuickAddSheet(position: position, recorderController: recorder)));
      await _settle(tester);

      await tester.enterText(find.widgetWithText(TextField, 'Type a name'), 'Grandma Rose');
      await tester.pump();

      // No person named "Grandma Rose" exists yet before save.
      late List<Person> before;
      await tester.runAsync(() async => before = await db.getPersons());
      expect(before, isEmpty);

      await _pressAsync(tester, find.widgetWithText(ActionChip, 'Add "Grandma Rose"'));
      await tester.pump();
      expect(find.widgetWithText(Chip, 'Grandma Rose'), findsOneWidget);

      await tester.enterText(
          find.widgetWithText(TextField, 'What happened here?'), 'A visit.');
      await tester.pump();
      await _pressAsync(tester, find.widgetWithText(FilledButton, 'Save story'));
      await _settle(tester);

      late List<Person> persons;
      late List<Event> events;
      await tester.runAsync(() async {
        persons = await db.getPersons();
        events = await db.getEvents();
      });
      expect(persons, hasLength(1));
      expect(persons.single.name, 'Grandma Rose');
      expect(events.single.participantIds, [persons.single.id]);
    });

    testWidgets('selecting an existing person reuses it instead of creating a new one',
        (tester) async {
      late DatabaseService db;
      late Person existing;
      await tester.runAsync(() async {
        db = createTestDatabaseService();
        await db.initialize();
        existing = Person(name: 'Uncle Bob');
        await db.savePerson(existing);
      });
      final capture = FakeAudioCapture();
      final recorder = _buildRecorder(capture: capture, db: db, tempDir: tempDir);
      final position = ValueNotifier<LatLng>(const LatLng(10, 10));

      await tester.pumpWidget(_wrap(
          db, QuickAddSheet(position: position, recorderController: recorder)));
      await _settle(tester);

      await tester.enterText(find.widgetWithText(TextField, 'Type a name'), 'Bob');
      await tester.pump();
      await _pressAsync(tester, find.widgetWithText(ActionChip, 'Uncle Bob'));
      await tester.pump();

      await tester.enterText(
          find.widgetWithText(TextField, 'What happened here?'), 'A chat.');
      await tester.pump();
      await _pressAsync(tester, find.widgetWithText(FilledButton, 'Save story'));
      await _settle(tester);

      late List<Person> persons;
      late List<Event> events;
      await tester.runAsync(() async {
        persons = await db.getPersons();
        events = await db.getEvents();
      });
      expect(persons, hasLength(1), reason: 'no new person should have been created');
      expect(events.single.participantIds, [existing.id]);
    });
  });

  group('nearby place proposal', () {
    testWidgets('proposes an existing place within ~50m and reuses it on tap',
        (tester) async {
      late DatabaseService db;
      late Place existingPlace;
      await tester.runAsync(() async {
        db = createTestDatabaseService();
        await db.initialize();
        existingPlace = Place(name: 'Grandma\'s house', latitude: 10.0, longitude: 10.0);
        await db.savePlace(existingPlace);
      });
      final capture = FakeAudioCapture();
      final recorder = _buildRecorder(capture: capture, db: db, tempDir: tempDir);
      // ~30m away (well within the 50m radius).
      final position = ValueNotifier<LatLng>(const LatLng(10.0002, 10.0002));

      await tester.pumpWidget(_wrap(
          db, QuickAddSheet(position: position, recorderController: recorder)));
      await _settle(tester);
      await _settle(tester);

      final proposalFinder = find.widgetWithText(ActionChip, 'Use "Grandma\'s house" (nearby)');
      expect(proposalFinder, findsOneWidget);

      await _pressAsync(tester, proposalFinder);
      await tester.pump();

      final nameField =
          tester.widget<TextField>(find.widgetWithText(TextField, 'Place name (optional)'));
      expect(nameField.controller!.text, 'Grandma\'s house');
      expect(nameField.enabled, isFalse);

      await tester.enterText(
          find.widgetWithText(TextField, 'What happened here?'), 'Sunday lunch.');
      await tester.pump();
      await _pressAsync(tester, find.widgetWithText(FilledButton, 'Save story'));
      await _settle(tester);

      late List<Place> places;
      late List<Event> events;
      await tester.runAsync(() async {
        places = await db.getPlaces();
        events = await db.getEvents();
      });
      expect(places, hasLength(1), reason: 'must reuse the existing place, not duplicate it');
      expect(events.single.placeId, existingPlace.id);
    });

    testWidgets('with no nearby place, saving creates a new one at the pin',
        (tester) async {
      late DatabaseService db;
      await tester.runAsync(() async {
        db = createTestDatabaseService();
        await db.initialize();
      });
      final capture = FakeAudioCapture();
      final recorder = _buildRecorder(capture: capture, db: db, tempDir: tempDir);
      final position = ValueNotifier<LatLng>(const LatLng(50, 50));

      await tester.pumpWidget(_wrap(
          db, QuickAddSheet(position: position, recorderController: recorder)));
      await _settle(tester);
      await _settle(tester);

      expect(find.byType(ActionChip), findsNothing);

      await tester.enterText(
          find.widgetWithText(TextField, 'Place name (optional)'), 'The old oak tree');
      await tester.enterText(
          find.widgetWithText(TextField, 'What happened here?'), 'We carved our initials.');
      await tester.pump();
      await _pressAsync(tester, find.widgetWithText(FilledButton, 'Save story'));
      await _settle(tester);

      late List<Place> places;
      await tester.runAsync(() async => places = await db.getPlaces());
      expect(places, hasLength(1));
      expect(places.single.name, 'The old oak tree');
      expect(places.single.latitude, 50);
    });
  });

  group('live transcript never overwrites what the user typed', () {
    testWidgets('typed text stays intact and the live transcript is appended after it',
        (tester) async {
      late DatabaseService db;
      await tester.runAsync(() async {
        db = createTestDatabaseService();
        await db.initialize();
      });
      final capture = FakeAudioCapture();
      final recorder = _buildRecorder(
          capture: capture, db: db, tempDir: tempDir, transcribedText: 'the sun was out');
      final position = ValueNotifier<LatLng>(const LatLng(10, 10));

      await tester.pumpWidget(_wrap(
          db, QuickAddSheet(position: position, recorderController: recorder)));
      await _settle(tester);

      final fieldFinder = find.widgetWithText(TextField, 'What happened here?');
      await tester.enterText(fieldFinder, 'We went to the park.');
      await tester.pump();

      // Place the cursor in the middle of what the user typed, simulating
      // an in-progress edit, and remember exactly where it is.
      final controller = tester.widget<TextField>(fieldFinder).controller!;
      controller.selection = const TextSelection.collapsed(offset: 7); // after "We went"
      await tester.pump();

      // Drive the recorder directly rather than through the button's
      // onTap: GestureDetector's onTap is void Function(), so tester.tap()
      // never actually awaits _toggleRecording()'s async body - including
      // start()'s own database write, which (like every sqflite call in
      // this suite) needs a real event-loop turn under tester.runAsync to
      // resolve at all. See the "recording in progress" test below for the
      // same pitfall with a full explanation.
      await tester.runAsync(() => recorder.start());
      await tester.pump();

      await tester.runAsync(() async {
        capture.emitChunk(Uint8List(3200)); // 100ms of 16kHz mono 16-bit PCM.
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      final textAfterLive = controller.text;
      expect(textAfterLive, startsWith('We went to the park.'),
          reason: 'the user\'s own text must never be overwritten or reordered');
      expect(textAfterLive, contains('the sun was out'));
      // The cursor the user left mid-edit must be untouched by the
      // programmatic append at the end.
      expect(controller.selection, const TextSelection.collapsed(offset: 7));
    });
  });

  group('unsaved-content confirmation', () {
    testWidgets('closing with nothing entered needs no confirmation', (tester) async {
      late DatabaseService db;
      await tester.runAsync(() async {
        db = createTestDatabaseService();
        await db.initialize();
      });
      final capture = FakeAudioCapture();
      final recorder = _buildRecorder(capture: capture, db: db, tempDir: tempDir);
      final position = ValueNotifier<LatLng>(const LatLng(10, 10));
      final key = GlobalKey<QuickAddSheetState>();

      await tester.pumpWidget(_wrap(db,
          QuickAddSheet(key: key, position: position, recorderController: recorder)));
      await _settle(tester);

      final canClose = await key.currentState!.confirmDiscardIfNeeded();
      expect(canClose, isTrue);
    });

    testWidgets('closing with typed text asks first, and Keep editing cancels the close',
        (tester) async {
      late DatabaseService db;
      await tester.runAsync(() async {
        db = createTestDatabaseService();
        await db.initialize();
      });
      final capture = FakeAudioCapture();
      final recorder = _buildRecorder(capture: capture, db: db, tempDir: tempDir);
      final position = ValueNotifier<LatLng>(const LatLng(10, 10));
      final key = GlobalKey<QuickAddSheetState>();

      await tester.pumpWidget(_wrap(db,
          QuickAddSheet(key: key, position: position, recorderController: recorder)));
      await _settle(tester);

      await tester.enterText(
          find.widgetWithText(TextField, 'What happened here?'), 'Half-written story');
      await tester.pump();

      final future = key.currentState!.confirmDiscardIfNeeded();
      await tester.pump();
      expect(find.text('Discard this story?'), findsOneWidget);

      await tester.tap(find.text('Keep editing'));
      await tester.pump();
      expect(await future, isFalse);
      // The text is still there - nothing was lost.
      expect(find.text('Half-written story'), findsOneWidget);
    });

    testWidgets(
        'a recording in progress is stopped and kept (not deleted) when the sheet is dismissed',
        (tester) async {
      late DatabaseService db;
      await tester.runAsync(() async {
        db = createTestDatabaseService();
        await db.initialize();
      });
      final capture = FakeAudioCapture();
      final recorder = _buildRecorder(capture: capture, db: db, tempDir: tempDir);
      final position = ValueNotifier<LatLng>(const LatLng(10, 10));
      final key = GlobalKey<QuickAddSheetState>();

      await tester.pumpWidget(_wrap(db,
          QuickAddSheet(key: key, position: position, recorderController: recorder)));
      await _settle(tester);

      await tester.runAsync(() => recorder.start());
      await tester.pump();
      expect(recorder.state, RecorderState.recording);

      // Stop the recording through the sheet's own record-button toggle
      // (not tester.tap(), which never awaits the async callback behind
      // it) BEFORE calling confirmDiscardIfNeeded(), so that call has no
      // database work left to do itself (recorder.state is already idle
      // by then) - only showDialog(), which is safe to call from the
      // normal test zone. Splitting it this way avoids ever needing to
      // call anything that shows a dialog from inside tester.runAsync():
      // that reliably hangs the test binding (Navigator/Overlay mutation
      // isn't safe there), which is why this doesn't just wrap
      // confirmDiscardIfNeeded() itself in runAsync.
      final recordButtonTap = tester
          .widget<GestureDetector>(find.descendant(
            of: find.bySemanticsLabel('Stop recording'),
            matching: find.byType(GestureDetector),
          ))
          .onTap!;
      await tester.runAsync(() async => await (recordButtonTap as Function)());
      await tester.pump();
      expect(recorder.state, RecorderState.idle,
          reason: 'must stop (and finalize) the recording, not abandon it mid-write');

      final future = key.currentState!.confirmDiscardIfNeeded();
      await tester.pump();

      expect(find.text(
          'The recording stays saved on this device (you can attach it to a story later); everything else will be lost.'),
          findsOneWidget);

      await tester.tap(find.text('Discard'));
      await tester.pump();
      expect(await future, isTrue);

      final recordingId = recorder.lastStopResult!.attachedFile.id;
      late LocalRecordingState? recording;
      await tester.runAsync(() async => recording = await db.getLocalRecording(recordingId));
      expect(recording, isNotNull, reason: 'the recording bytes/bookkeeping must survive');
      expect(recording!.eventId, isNull, reason: 'orphaned until attached to a story');
    });
  });
}
