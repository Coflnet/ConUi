import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/services/app_settings_service.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/interaction_feedback.dart';
import 'package:relationship_manager/services/recorder_controller.dart';
import 'package:relationship_manager/services/recording_file_store.dart';
import 'package:relationship_manager/services/recording_file_store_native.dart';
import 'package:relationship_manager/services/transcription_client.dart';

import '../support/fake_audio_capture.dart';
import '../support/fake_speech_detector.dart';
import '../support/test_database.dart';

class _DelayedRecordingStore extends RecordingFileStore {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> beginRecording(String id,
      {WavFormat format = WavFormat.standard}) async {
    entered.complete();
    await release.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingDatabase extends DatabaseService {
  @override
  Future<void> saveLocalRecording(LocalRecordingState recording) async {}
}

class _FailsFirstFinalizationStore extends NativeRecordingFileStore {
  int attempts = 0;
  _FailsFirstFinalizationStore(Directory directory)
      : super(baseDirectory: directory);

  @override
  Future<RecordingFinalizeResult> finalizeRecording(String id,
      {WavFormat format = WavFormat.standard}) async {
    attempts++;
    final result = await super.finalizeRecording(id, format: format);
    // Fail after the file was finalized, exercising retry of an existing WAV.
    if (attempts == 1) {
      throw const FileSystemException('Finalization interrupted');
    }
    return result;
  }
}

void main() {
  test('overlapping recording starts both wait until the start cue stops',
      () async {
    final pendingSound = Completer<void>();
    final soundStarted = Completer<void>();
    final cues = <FeedbackCue>[];
    final settings = AppSettingsService()..soundsEnabled = true;
    final feedback = InteractionFeedback(settings, soundPlayer: (cue) async {
      cues.add(cue);
      if (cue == FeedbackCue.recordingStart) {
        soundStarted.complete();
        await pendingSound.future;
      }
    }, hapticPlayer: (_) async {});
    addTearDown(feedback.dispose);
    var firstCanCapture = false;
    final first = feedback.beginRecording().then((_) => firstCanCapture = true);
    await soundStarted.future;
    var secondCanCapture = false;
    final second =
        feedback.beginRecording().then((_) => secondCanCapture = true);
    await Future<void>.delayed(Duration.zero);
    expect(firstCanCapture, isFalse);
    expect(secondCanCapture, isFalse);
    pendingSound.complete();
    await Future.wait([first, second]);
    expect(firstCanCapture, isTrue);
    expect(secondCanCapture, isTrue);
    expect(cues, [FeedbackCue.recordingStart]);
    await feedback.endRecording(silent: true);
    await feedback.play(FeedbackCue.success);
    expect(cues, [FeedbackCue.recordingStart],
        reason: 'The second capture still suppresses feedback.');
    await feedback.endRecording(silent: true);
    await feedback.play(FeedbackCue.success);
    expect(cues, [FeedbackCue.recordingStart, FeedbackCue.success]);
  });

  test('disposal during durability initialization cannot resume recording',
      () async {
    final store = _DelayedRecordingStore();
    final capture = FakeAudioCapture();
    var pageHooks = 0;
    final controller = RecorderController(
      audioCapture: capture,
      fileStore: store,
      database: _RecordingDatabase(),
      createSpeechDetector: () async => null,
      transcriptionClient:
          TranscriptionClient(baseUrl: '', getToken: () => 'signed'),
      registerPageHideHook: (_) {
        pageHooks++;
        return () {};
      },
    );
    final start = controller.start();
    await store.entered.future;
    expect(capture.isRecording, isTrue);
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(capture.isRecording, isFalse);
    store.release.complete();
    await start;
    expect(controller.state, isNot(RecorderState.recording));
    expect(pageHooks, 0);
    await capture.dispose();
  });

  test(
      'failed finalization retries the original recording without changing PCM',
      () async {
    final directory =
        Directory.systemTemp.createTempSync('feedback_lifecycle_');
    final db = createTestDatabaseService();
    await db.initialize();
    final store = _FailsFirstFinalizationStore(directory);
    final capture = FakeAudioCapture();
    final controller = RecorderController(
      audioCapture: capture,
      fileStore: store,
      database: db,
      createSpeechDetector: () async => EndingDetector(detectsSpeech: false),
      transcriptionClient:
          TranscriptionClient(baseUrl: '', getToken: () => 'signed'),
    );
    addTearDown(() async {
      controller.dispose();
      await capture.dispose();
      await (await db.database).close();
      directory.deleteSync(recursive: true);
    });
    await controller.start();
    final id = controller.recordingId!;
    final pcm = Uint8List.fromList(List.generate(6400, (i) => i % 251));
    capture.emitChunk(pcm);
    await Future<void>.delayed(Duration.zero);
    await expectLater(controller.stop(), throwsA(isA<FileSystemException>()));
    expect(controller.state, RecorderState.failed);
    expect(controller.canRetryStop, isTrue);
    expect(capture.isRecording, isFalse);
    expect(controller.recordingId, id);
    expect((await store.readBytes(id)).sublist(wavHeaderLength),
        orderedEquals(pcm));

    // A new start must not replace the recording that still needs saving.
    await controller.start();
    expect(controller.recordingId, id);
    expect(capture.isRecording, isFalse);
    final result = await controller.stop();
    expect(store.attempts, 2);
    expect(result.attachedFile.id, id);
    expect(result.attachedFile.size, wavHeaderLength + pcm.length);
    expect(controller.recordingId, id);
    expect(controller.state, RecorderState.idle);
    expect(controller.canRetryStop, isFalse);
    expect((await store.readBytes(id)).sublist(wavHeaderLength),
        orderedEquals(pcm));
    expect((await db.getLocalRecording(id))!.state,
        RecordingLifecycleState.complete);
  });
}
