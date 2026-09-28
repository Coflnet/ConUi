// Widget test for EventDetailScreen showing a recording with a working
// player (play/pause, seek, duration), built on RecordingFileStore so it
// works on native and web alike.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/screens/events/event_detail_screen.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/recording_file_store_native.dart';
import 'package:relationship_manager/widgets/recording_player.dart';

import '../support/test_database.dart';

/// audioplayers talks to the platform over a MethodChannel plus a
/// per-instance EventChannel (name includes a random player id); nothing
/// implements either in a plain `flutter test` run (no real
/// Android/iOS/web audio stack, and the EventChannel's dynamic name can't
/// be pre-registered). This stub covers the MethodChannel so AudioPlayer's
/// own setup calls don't throw; the EventChannel's MissingPluginException
/// is expected and drained via tester.takeException() below - actual
/// playback can't be exercised in this harness, only that RecordingPlayer
/// builds and wires up its UI on top of RecordingFileStore.
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

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('event_detail_screen_test');
    _stubAudioplayersChannel();
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  testWidgets('shows a recording with a player', (tester) async {
    late DatabaseService db;
    final store = NativeRecordingFileStore(baseDirectory: tempDir);
    late Event event;

    await tester.runAsync(() async {
      db = createTestDatabaseService();
      await db.initialize();

      await store.beginRecording('rec1');
      await store.appendChunk('rec1', Uint8List(1600));
      final result = await store.finalizeRecording('rec1');

      event = Event(
        title: 'Grandma at the lake',
        dateTime: DateTime(2020, 6, 1),
        files: [
          AttachedFile(
            id: 'rec1',
            fileName: 'rec1.wav',
            filePath: 'rec1',
            mimeType: 'audio/wav',
            size: result.sizeBytes,
            durationMs: result.durationMs,
            sha256: result.sha256Hex,
            kind: AttachedFile.kindRecording,
          ),
        ],
      );
      await db.saveEvent(event);
    });

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChangeNotifierProvider<DatabaseService>.value(
          value: db,
          child: EventDetailScreen(eventId: event.id, recordingFileStore: store),
        ),
      ),
    );

    // Let the FutureBuilder's database query (real FFI I/O) resolve.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    // The EventChannel MissingPluginException (see _stubAudioplayersChannel's
    // doc comment) surfaces asynchronously around here; drain it so it
    // doesn't fail the test.
    tester.takeException();
    // RecordingPlayer now plays from a DeviceFileSource (see the class doc
    // comment) instead of a data: URI; with no real platform behind it,
    // audioplayers never emits an onPrepared event, so its internal 30s
    // "prepared" wait (AudioPlayer._completePrepared) is genuinely pending
    // rather than just needing a moment - flush it with a fake-clock pump
    // (not runAsync, which only drives real time) so it times out, is
    // caught by RecordingPlayer's own error handling, and doesn't leave a
    // dangling Timer for the test binding to complain about.
    await tester.pump(const Duration(seconds: 31));
    tester.takeException();

    expect(find.text('Grandma at the lake'), findsOneWidget);
    expect(find.text('Recordings'), findsOneWidget);
    expect(find.byType(RecordingPlayer), findsOneWidget,
        reason: 'a recording-kind attachment should render through RecordingPlayer');
  });
}
