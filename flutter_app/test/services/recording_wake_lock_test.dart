import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/services/audio_capture.dart';
import 'package:relationship_manager/services/recorder_controller.dart';
import 'package:relationship_manager/services/recording_file_store.dart';
import 'package:relationship_manager/services/recording_file_store_native.dart';
import 'package:relationship_manager/services/recording_wake_lock.dart';
import 'package:relationship_manager/services/transcription_client.dart';

import '../support/fake_audio_capture.dart';
import '../support/test_database.dart';

class _ControlledCapture extends FakeAudioCapture {
  bool failStop = false;

  @override
  Future<void> stop() async {
    await super.stop();
    if (failStop) throw StateError('Capture stop interrupted');
  }
}

class _ControlledStore extends NativeRecordingFileStore {
  bool failBegin = false;
  Completer<void>? finalizeEntered;
  Completer<void>? finalizeRelease;

  _ControlledStore(Directory directory) : super(baseDirectory: directory);

  @override
  Future<void> beginRecording(String id,
      {WavFormat format = WavFormat.standard}) async {
    if (failBegin) throw const FileSystemException('Storage unavailable');
    await super.beginRecording(id, format: format);
  }

  @override
  Future<RecordingFinalizeResult> finalizeRecording(String id,
      {WavFormat format = WavFormat.standard}) async {
    finalizeEntered?.complete();
    await finalizeRelease?.future;
    return super.finalizeRecording(id, format: format);
  }
}

void main() {
  test(
      'a release waits for pending acquisition before disabling the screen lock',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final calls = <bool>[];
    final lock = RecordingWakeLock(toggle: ({required enable}) async {
      calls.add(enable);
      if (enable) {
        entered.complete();
        await release.future;
      }
    });
    final enabling = lock.setEnabled(true);
    await entered.future;
    final disabling = lock.setEnabled(false);
    expect(calls, [true]);
    release.complete();
    await Future.wait([enabling, disabling]);
    expect(calls, [true, false]);
  });

  test('overlapping recordings keep the screen awake until the last stops',
      () async {
    final calls = <bool>[];
    Future<void> toggle({required bool enable}) async => calls.add(enable);
    final first = RecordingWakeLock(toggle: toggle);
    final second = RecordingWakeLock(toggle: toggle);
    addTearDown(() async {
      await first.setEnabled(false);
      await second.setEnabled(false);
    });
    await first.setEnabled(true);
    await first.setEnabled(true);
    await second.setEnabled(true);
    await first.setEnabled(false);
    expect(calls, [true]);
    await second.setEnabled(false);
    expect(calls, [true, false]);
  });

  test('platform acquisition and release errors do not break future requests',
      () async {
    final calls = <bool>[];
    final lock = RecordingWakeLock(toggle: ({required enable}) async {
      calls.add(enable);
      throw StateError('Wake lock unavailable');
    });
    await lock.setEnabled(true);
    await lock.setEnabled(false);
    await lock.setEnabled(true);
    await lock.setEnabled(false);
    expect(calls, [true, false, true, false]);
  });

  group('recording capture lifecycle', () {
    late Directory directory;
    late _ControlledStore store;
    late _ControlledCapture capture;
    late RecordingWakeLock lock;
    late RecorderController controller;
    late List<bool> calls;
    late void Function() pageHidden;
    Completer<void>? pendingEnable;
    var disposed = false;
    late Completer<void> lockReleased;

    setUp(() async {
      directory = Directory.systemTemp.createTempSync('recording_wake_lock_');
      store = _ControlledStore(directory);
      capture = _ControlledCapture();
      calls = [];
      pendingEnable = null;
      disposed = false;
      lockReleased = Completer<void>();
      lock = RecordingWakeLock(toggle: ({required enable}) async {
        calls.add(enable);
        if (enable) await pendingEnable?.future;
        if (!enable) lockReleased.complete();
      });
      final db = createTestDatabaseService();
      await db.initialize();
      controller = RecorderController(
        audioCapture: capture,
        fileStore: store,
        database: db,
        transcriptionClient:
            TranscriptionClient(baseUrl: '', getToken: () => 'signed'),
        createSpeechDetector: () async => null,
        wakeLock: lock,
        registerPageHideHook: (callback) {
          pageHidden = callback;
          return () {};
        },
      );
      addTearDown(() async {
        if (!disposed) controller.dispose();
        await lock.setEnabled(false);
        await capture.dispose();
        await (await db.database).close();
        directory.deleteSync(recursive: true);
      });
    });

    for (final hidden in [false, true]) {
      test(
          '${hidden ? 'page hide' : 'manual stop'} releases before finalization completes',
          () async {
        store.finalizeEntered = Completer<void>();
        store.finalizeRelease = Completer<void>();
        await controller.start();
        expect(calls, [true]);
        Future<RecorderStopResult>? stopping;
        if (hidden) {
          pageHidden();
        } else {
          stopping = controller.stop();
        }
        await store.finalizeEntered!.future;
        expect(controller.state, RecorderState.finishing);
        expect(capture.isRecording, isFalse);
        expect(calls, [true, false]);
        final finished = Completer<void>();
        controller.addListener(() {
          if (controller.state == RecorderState.idle && !finished.isCompleted) {
            finished.complete();
          }
        });
        store.finalizeRelease!.complete();
        if (stopping != null) await stopping;
        await finished.future;
      });
    }

    test('permission denial never acquires the screen lock', () async {
      capture.failureOnStart = AudioCaptureException(
          AudioCaptureFailureReason.permissionDenied, 'denied');
      await controller.start();
      expect(controller.state, RecorderState.failed);
      expect(calls, isEmpty);
    });

    test('storage initialization failure releases the screen lock', () async {
      store.failBegin = true;
      await controller.start();
      await lockReleased.future.timeout(const Duration(seconds: 5));
      expect(controller.state, RecorderState.failed);
      expect(capture.isRecording, isFalse);
      expect(calls, [true, false]);
    });

    test('capture stop failure still releases the screen lock', () async {
      await controller.start();
      capture.failStop = true;
      await expectLater(controller.stop(), throwsStateError);
      await lockReleased.future.timeout(const Duration(seconds: 5));
      expect(controller.state, RecorderState.failed);
      expect(controller.canRetryStop, isTrue);
      expect(capture.isRecording, isFalse);
      expect(calls, [true, false]);
    });

    test('disposal during pending acquisition releases the eventual lock',
        () async {
      pendingEnable = Completer<void>();
      await controller.start();
      expect(calls, [true]);
      controller.dispose();
      disposed = true;
      pendingEnable!.complete();
      await lockReleased.future.timeout(const Duration(seconds: 5));
      expect(capture.isRecording, isFalse);
      expect(calls, [true, false]);
    });
  });
}
