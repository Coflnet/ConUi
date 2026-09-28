// Widget tests for the recovered-recordings banner: hidden with nothing to
// show, visible with a count when recordings exist that aren't attached to
// any story, and its delete action (with confirmation) permanently removes
// one, per RecordingFileStore's deletion rule.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/recording_file_store_native.dart';
import 'package:relationship_manager/widgets/recovered_recordings_banner.dart';

import '../support/test_database.dart';

// See event_detail_screen_test.dart's identical helper for why this is
// needed: RecordingPlayer (used to "listen" to a recovered recording)
// talks to audioplayers over a MethodChannel that nothing implements in a
// plain `flutter test` run.
void _stubAudioplayersChannel() {
  const channel = MethodChannel('xyz.luan/audioplayers');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    switch (call.method) {
      case 'getDuration':
      case 'getCurrentPosition':
        return 0;
      default:
        return null;
    }
  });
}

// The provider wraps the whole MaterialApp, not just `home`: "Review" opens
// a new route (showModalBottomSheet) as a sibling of `home` in the
// Navigator's Overlay, not its descendant - a provider scoped inside
// `home` alone wouldn't be visible to that route's content.
Widget _wrap(DatabaseService db, Widget child) {
  return ChangeNotifierProvider<DatabaseService>.value(
    value: db,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 2; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
}

void main() {
  late Directory tempDir;
  late NativeRecordingFileStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('recovered_recordings_banner_test');
    store = NativeRecordingFileStore(baseDirectory: tempDir);
    _stubAudioplayersChannel();
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> seedOrphanedRecording(DatabaseService db, String id) async {
    await store.beginRecording(id);
    await store.appendChunk(id, Uint8List(1600));
    final result = await store.finalizeRecording(id);
    await db.saveLocalRecording(LocalRecordingState(
      id: id,
      state: RecordingLifecycleState.complete,
      sizeBytes: result.sizeBytes,
      sha256: result.sha256Hex,
      durationMs: result.durationMs,
    ));
  }

  testWidgets('shows nothing when there are no orphaned recordings', (tester) async {
    late DatabaseService db;
    await tester.runAsync(() async {
      db = createTestDatabaseService();
      await db.initialize();
    });

    await tester.pumpWidget(_wrap(
        db, RecoveredRecordingsBanner(store: store, pickerStartPosition: const LatLng(0, 0))));
    await _settle(tester);

    expect(find.byType(MaterialBanner), findsNothing);
  });

  testWidgets('shows a count banner when recordings exist that are not attached to a story',
      (tester) async {
    late DatabaseService db;
    await tester.runAsync(() async {
      db = createTestDatabaseService();
      await db.initialize();
      await seedOrphanedRecording(db, 'rec-a');
      await seedOrphanedRecording(db, 'rec-b');
    });

    await tester.pumpWidget(_wrap(
        db, RecoveredRecordingsBanner(store: store, pickerStartPosition: const LatLng(0, 0))));
    await _settle(tester);

    expect(find.text('2 recordings are not attached to a story'), findsOneWidget);
  });

  testWidgets('a recording attached to an event is not counted as orphaned', (tester) async {
    late DatabaseService db;
    await tester.runAsync(() async {
      db = createTestDatabaseService();
      await db.initialize();
      await seedOrphanedRecording(db, 'rec-attached');
      await db.saveLocalRecording(LocalRecordingState(
        id: 'rec-attached',
        eventId: 'some-event-id',
        state: RecordingLifecycleState.complete,
      ));
    });

    await tester.pumpWidget(_wrap(
        db, RecoveredRecordingsBanner(store: store, pickerStartPosition: const LatLng(0, 0))));
    await _settle(tester);

    expect(find.byType(MaterialBanner), findsNothing);
  });

  testWidgets('Review lists the recording with a Delete action that asks for confirmation first',
      (tester) async {
    late DatabaseService db;
    await tester.runAsync(() async {
      db = createTestDatabaseService();
      await db.initialize();
      await seedOrphanedRecording(db, 'rec-delete-me');
    });

    await tester.pumpWidget(_wrap(
        db, RecoveredRecordingsBanner(store: store, pickerStartPosition: const LatLng(0, 0))));
    await _settle(tester);

    expect(find.text('1 recording is not attached to a story'), findsOneWidget);

    // Not pumpAndSettle(): RecordingPlayer's AudioPlayer keeps its own
    // internal timers alive (position polling etc.) with nothing real
    // behind them in this harness, so pumpAndSettle would never return -
    // a bounded number of plain pumps is enough for the sheet/dialog
    // transitions to settle.
    await tester.tap(find.text('Review'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    tester.takeException(); // the RecordingPlayer's EventChannel MissingPluginException.

    // The row's Delete button calls _delete(), which is async (shows the
    // confirm dialog, then - once answered - does the real database
    // work), but Dart still runs an async function's body synchronously up
    // to its first await - so a plain tester.tap() (deliberately NOT
    // wrapped in runAsync: showDialog()/Navigator.push() must run in the
    // normal test zone, not the real one runAsync provides - doing so
    // hangs the test binding) is enough to reach and show the dialog.
    // Nothing async has happened yet at that point, so this doesn't need
    // runAsync at all; deleteRecordingPermanently's actual effect (bytes
    // and bookkeeping both gone) is covered directly, without any
    // dialog/zone interaction, in the plain test below.
    expect(find.widgetWithText(TextButton, 'Delete'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pump();

    expect(find.text('Delete this recording?'), findsOneWidget);
    expect(
        find.text('This permanently deletes the audio. This cannot be undone.'),
        findsOneWidget);
  });

  test('deleteRecordingPermanently removes both the bytes and the bookkeeping row', () async {
    final db = createTestDatabaseService();
    await db.initialize();
    await seedOrphanedRecording(db, 'rec-delete-me');

    expect(await store.exists('rec-delete-me'), isTrue);
    expect(await db.getLocalRecording('rec-delete-me'), isNotNull);

    await db.deleteRecordingPermanently('rec-delete-me', store);

    expect(await store.exists('rec-delete-me'), isFalse,
        reason: 'the audio bytes must be permanently gone');
    expect(await db.getLocalRecording('rec-delete-me'), isNull,
        reason: 'the local bookkeeping row must be gone too');
  });
}
