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
import 'package:relationship_manager/services/recording_file_store.dart'
    show PlaybackSource;
import 'package:relationship_manager/widgets/recording_player.dart';

import '../support/test_database.dart';

/// Stub the method channel and each player-created event channel; widget tests
/// have no media platform. Actual playback preparation still times out below.
void _stubAudioplayersChannel() {
  const channel = MethodChannel('xyz.luan/audioplayers');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    switch (call.method) {
      case 'create':
        final id = (call.arguments as Map)['playerId'];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
                MethodChannel('xyz.luan/audioplayers/events/$id'),
                (_) async => null);
        return null;
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
          child:
              EventDetailScreen(eventId: event.id, recordingFileStore: store),
        ),
      ),
    );

    // Let the FutureBuilder's database query (real FFI I/O) resolve.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    // RecordingPlayer now plays from a DeviceFileSource (see the class doc
    // comment) instead of a data: URI; with no real platform behind it,
    // audioplayers never emits an onPrepared event, so its internal 30s
    // "prepared" wait (AudioPlayer._completePrepared) is genuinely pending
    // rather than just needing a moment - flush it with a fake-clock pump
    // (not runAsync, which only drives real time) so it times out, is
    // caught by RecordingPlayer's own error handling, and doesn't leave a
    // dangling Timer for the test binding to complain about.
    await tester.pump(const Duration(seconds: 31));

    expect(find.text('Grandma at the lake'), findsOneWidget);
    expect(find.text('Recordings'), findsOneWidget);
    expect(find.byType(RecordingPlayer), findsOneWidget,
        reason:
            'a recording-kind attachment should render through RecordingPlayer');
  });

  for (final deleteAudio in [true, false]) {
    testWidgets(
        deleteAudio
            ? 'permanent story deletion removes recording references from its sync tombstone'
            : 'keep-recording deletion preserves recording references and original bytes',
        (tester) async {
      late DatabaseService db;
      final store = _DeletionRecordingStore(tempDir);
      late Event event;
      late Uint8List original;
      await tester.runAsync(() async {
        db = createTestDatabaseService();
        await db.initialize();
        await store.beginRecording('rec1');
        await store.appendChunk('rec1', Uint8List(1600));
        final recording = await store.finalizeRecording('rec1');
        original = await store.readBytes('rec1');
        event = Event(
          title: 'Story with recording',
          dateTime: DateTime(2020),
          files: [
            AttachedFile(
                id: 'rec1',
                fileName: 'rec1.wav',
                filePath: 'rec1',
                mimeType: 'audio/wav',
                size: recording.sizeBytes,
                kind: AttachedFile.kindRecording),
            AttachedFile(
                id: 'photo',
                fileName: 'photo.jpg',
                filePath: 'photo',
                mimeType: 'image/jpeg',
                size: 10),
          ],
        );
        await db.saveEvent(event);
      });
      await tester.pumpWidget(ChangeNotifierProvider<DatabaseService>.value(
        value: db,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
              builder: (context) => Scaffold(
                      body: TextButton(
                    onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => EventDetailScreen(
                                eventId: event.id, recordingFileStore: store))),
                    child: const Text('Open story'),
                  ))),
        ),
      ));
      await tester.tap(find.text('Open story'));
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      await _settleIo(tester);
      await tester.tap(find.byIcon(Icons.delete));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text(deleteAudio
          ? 'Delete story + recording'
          : 'Delete story, keep recording'));
      await _settleIo(tester);
      await tester.pumpAndSettle();

      await tester.runAsync(() async {
        final tombstone = (await db.getEvent(event.id))!;
        expect(tombstone.isDeleted, isTrue);
        expect(tombstone.files.map((file) => file.id),
            deleteAudio ? ['photo'] : ['rec1', 'photo']);
        final pending = (await db.getPendingChanges())
            .lastWhere((change) => change.entityId == event.id);
        expect(pending.data['isDeleted'], isTrue);
        expect((pending.data['files'] as List).map((file) => file['id']),
            deleteAudio ? ['photo'] : ['rec1', 'photo']);
        expect(await store.exists('rec1'), !deleteAudio);
        if (!deleteAudio) expect(await store.readBytes('rec1'), original);
      });
      expect(find.text('Open story'), findsOneWidget);
    });
  }
}

// These tests verify real stored WAV bytes and tombstones without waiting for
// a media platform to prepare a player (playback is covered by the test above).
class _DeletionRecordingStore extends NativeRecordingFileStore {
  _DeletionRecordingStore(Directory directory)
      : super(baseDirectory: directory);

  @override
  Future<PlaybackSource> openPlaybackSource(String id) async =>
      throw UnsupportedError('No playback platform in deletion tests');
}

Future<void> _settleIo(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}
