// Thorough unit tests for RecorderController against fakes: ordering,
// retries, failure isolation, offline behaviour, the in-flight request
// limit, segment cutting, and that audio is stored completely even when
// every transcription request fails.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/services/audio_capture.dart';
import 'package:relationship_manager/services/recorder_controller.dart';
import 'package:relationship_manager/services/recording_file_store_native.dart';
import 'package:relationship_manager/services/transcription_client.dart';
import 'package:relationship_manager/services/wav.dart';

import '../support/fake_audio_capture.dart';
import '../support/test_database.dart';
import 'package:relationship_manager/services/database_service.dart';

// A short, fixed segment duration (well under 1s) makes tests fast and
// deterministic: with the default WavFormat (16kHz mono 16-bit), 100ms is
// exactly 3200 bytes, so chunks below can be sized to land on segment
// boundaries precisely.
const _segmentDuration = Duration(milliseconds: 100);
const _bytesPerSegment = 3200;

Uint8List _pcmChunk(int amplitude, int byteLength) {
  final bytes = ByteData(byteLength);
  for (var i = 0; i + 1 < byteLength; i += 2) {
    bytes.setInt16(i, amplitude, Endian.little);
  }
  return bytes.buffer.asUint8List();
}

void main() {
  late Directory tempDir;
  late NativeRecordingFileStore store;
  late DatabaseService db;
  late FakeAudioCapture capture;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('recorder_controller_test');
    store = NativeRecordingFileStore(baseDirectory: tempDir);
    db = createTestDatabaseService();
    await db.initialize();
    capture = FakeAudioCapture();
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  RecorderController buildController({
    required TranscriptionClient client,
    Duration segmentDuration = _segmentDuration,
    Duration maxDuration = const Duration(hours: 2),
    int maxSegmentRetries = 2,
  }) {
    return RecorderController(
      audioCapture: capture,
      fileStore: store,
      database: db,
      transcriptionClient: client,
      segmentDuration: segmentDuration,
      maxDuration: maxDuration,
      maxSegmentRetries: maxSegmentRetries,
      backoff: (_) => Duration.zero,
    );
  }

  TranscriptionClient echoClient({
    Future<http.Response> Function(http.Request)? handler,
  }) {
    return TranscriptionClient(
      baseUrl: 'https://api.example.com',
      getToken: () => 'tok',
      httpClient: MockClient(handler ??
          (request) async => http.Response(
              '{"text": "seg-${request.bodyBytes.length}"}', 200)),
    );
  }

  test('start() then stop() with no audio produces an empty-but-valid recording',
      () async {
    final controller = buildController(client: echoClient());
    await controller.start();
    expect(controller.state, RecorderState.recording);

    final result = await controller.stop();

    expect(result.attachedFile.size, wavHeaderLength);
    expect(result.attachedFile.kind, 'recording');
    expect(result.transcript, '');
    expect(result.failedSegments, isEmpty);
    expect(controller.state, RecorderState.idle);
  });

  test('start() surfaces a permission-denied failure without throwing', () async {
    capture.failureOnStart = AudioCaptureException(
        AudioCaptureFailureReason.permissionDenied, 'no mic for you');
    final controller = buildController(client: echoClient());

    await controller.start();

    expect(controller.state, RecorderState.failed);
    expect(controller.failure?.reason, AudioCaptureFailureReason.permissionDenied);
  });

  test('transcribes two segments and assembles the transcript in sequence order',
      () async {
    final requestOrder = <int>[];
    final controller = buildController(
      client: echoClient(handler: (request) async {
        // Identify which segment this is by its distinct amplitude
        // (encoded as the first sample), and respond with a matching
        // label - regardless of arrival order.
        final amplitude = ByteData.sublistView(request.bodyBytes, wavHeaderLength)
            .getInt16(0, Endian.little);
        requestOrder.add(amplitude);
        return http.Response('{"text": "seg$amplitude"}', 200);
      }),
    );

    await controller.start();
    capture.emitChunk(_pcmChunk(100, _bytesPerSegment)); // segment 0
    capture.emitChunk(_pcmChunk(200, _bytesPerSegment)); // segment 1
    await Future<void>.delayed(Duration.zero);

    final result = await controller.stop();

    expect(requestOrder, containsAll([100, 200]));
    expect(result.transcript, 'seg100 seg200');
    expect(result.failedSegments, isEmpty);
  });

  test('assembles in sequence order even when answers arrive out of order',
      () async {
    // Segment 0's response is deliberately delayed past segment 1's, so
    // segment 1 resolves first. The assembled transcript must still read
    // "first second", not "second first".
    final gate0 = Completer<void>();
    final controller = buildController(
      client: echoClient(handler: (request) async {
        final amplitude = ByteData.sublistView(request.bodyBytes, wavHeaderLength)
            .getInt16(0, Endian.little);
        if (amplitude == 111) {
          await gate0.future;
          return http.Response('{"text": "first"}', 200);
        }
        return http.Response('{"text": "second"}', 200);
      }),
    );

    await controller.start();
    capture.emitChunk(_pcmChunk(111, _bytesPerSegment)); // segment 0 -> "first"
    capture.emitChunk(_pcmChunk(222, _bytesPerSegment)); // segment 1 -> "second"
    await Future<void>.delayed(Duration.zero);

    // Let segment 1 (second) resolve well before segment 0 (first).
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(controller.liveTranscript, 'second');

    gate0.complete();
    final result = await controller.stop();

    expect(result.transcript, 'first second');
  });

  test('retries a failing segment with backoff and eventually succeeds',
      () async {
    var attempts = 0;
    final controller = buildController(
      client: echoClient(handler: (request) async {
        attempts++;
        if (attempts < 3) {
          return http.Response(
              '{"slug": "transcription_failed", "message": "try again"}', 502);
        }
        return http.Response('{"text": "ok after retries"}', 200);
      }),
      maxSegmentRetries: 3,
    );

    await controller.start();
    capture.emitChunk(_pcmChunk(50, _bytesPerSegment));
    await Future<void>.delayed(Duration.zero);

    final result = await controller.stop();

    expect(attempts, 3);
    expect(result.transcript, 'ok after retries');
    expect(result.failedSegments, isEmpty);
  });

  test(
      'a segment that always fails is isolated: marked failed, others still succeed, recording still completes',
      () async {
    final controller = buildController(
      client: echoClient(handler: (request) async {
        final amplitude = ByteData.sublistView(request.bodyBytes, wavHeaderLength)
            .getInt16(0, Endian.little);
        if (amplitude == 999) {
          return http.Response('{"slug": "transcription_failed"}', 502);
        }
        return http.Response('{"text": "good$amplitude"}', 200);
      }),
      maxSegmentRetries: 1,
    );

    await controller.start();
    capture.emitChunk(_pcmChunk(999, _bytesPerSegment)); // always fails
    capture.emitChunk(_pcmChunk(42, _bytesPerSegment)); // always succeeds
    await Future<void>.delayed(Duration.zero);

    final result = await controller.stop();

    expect(result.failedSegments, hasLength(1));
    expect(result.transcript, 'good42');
    // The failing segment's audio is still fully present in the file -
    // both segments' bytes plus the header.
    expect(result.attachedFile.size, wavHeaderLength + _bytesPerSegment * 2);
  });

  test(
      'when every transcription request fails, the audio is still stored completely',
      () async {
    final controller = buildController(
      client: echoClient(
          handler: (request) async => http.Response('{"slug": "down"}', 502)),
      maxSegmentRetries: 1,
    );

    await controller.start();
    capture.emitChunk(_pcmChunk(1, _bytesPerSegment));
    capture.emitChunk(_pcmChunk(2, _bytesPerSegment));
    capture.emitChunk(_pcmChunk(3, _bytesPerSegment ~/ 2)); // partial final segment
    await Future<void>.delayed(Duration.zero);

    final result = await controller.stop();

    expect(result.failedSegments, hasLength(3));
    expect(result.transcript, '');
    const expectedDataLength = _bytesPerSegment * 2 + _bytesPerSegment ~/ 2;
    expect(result.attachedFile.size, wavHeaderLength + expectedDataLength);
    expect(result.attachedFile.sha256, isNotNull);

    // And the bytes are genuinely readable back out of the store.
    final bytes = await store.readBytes(result.attachedFile.id);
    expect(WavHeader.readDataLength(bytes), expectedDataLength);
  });

  test('offline (no backend configured): recording works, reason says offline',
      () async {
    final offlineClient = TranscriptionClient(baseUrl: '', getToken: () => 'tok');
    final controller = buildController(client: offlineClient, maxSegmentRetries: 0);

    await controller.start();
    capture.emitChunk(_pcmChunk(7, _bytesPerSegment));
    await Future<void>.delayed(Duration.zero);

    final result = await controller.stop();

    expect(controller.liveTranscriptionReason, LiveTranscriptionReason.offline);
    expect(result.failedSegments, hasLength(1));
    expect(result.attachedFile.size, wavHeaderLength + _bytesPerSegment);
  });

  test('not signed in: recording works, reason says notSignedIn', () async {
    final signedOutClient =
        TranscriptionClient(baseUrl: 'https://api.example.com', getToken: () => null);
    final controller = buildController(client: signedOutClient, maxSegmentRetries: 0);

    await controller.start();
    capture.emitChunk(_pcmChunk(7, _bytesPerSegment));
    await Future<void>.delayed(Duration.zero);

    await controller.stop();

    expect(controller.liveTranscriptionReason, LiveTranscriptionReason.notSignedIn);
  });

  test('at most 2 transcription requests are in flight at once', () async {
    var active = 0;
    var maxActive = 0;
    final release = <Completer<void>>[];
    final controller = buildController(
      client: echoClient(handler: (request) async {
        active++;
        maxActive = active > maxActive ? active : maxActive;
        final gate = Completer<void>();
        release.add(gate);
        await gate.future;
        active--;
        return http.Response('{"text": "ok"}', 200);
      }),
    );

    await controller.start();
    // Cut four segments in quick succession.
    for (var i = 0; i < 4; i++) {
      capture.emitChunk(_pcmChunk(10 + i, _bytesPerSegment));
    }
    // Give the append chain a moment to process all four chunks and cut
    // all four segments, without releasing any HTTP responses yet.
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(maxActive, lessThanOrEqualTo(2));
    expect(active, 2); // exactly the concurrency limit should be in flight

    // Release them all so stop() can finish.
    for (final gate in release) {
      if (!gate.isCompleted) gate.complete();
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    for (final gate in release) {
      if (!gate.isCompleted) gate.complete();
    }

    final result = await controller.stop();
    expect(result.failedSegments, isEmpty);
  });

  test('stops automatically when maxDuration is reached', () async {
    final controller = buildController(
      client: echoClient(),
      maxDuration: const Duration(milliseconds: 150),
    );

    await controller.start();
    // Wait past maxDuration for the periodic ticker (every 200ms... but
    // maxDuration is 150ms) to notice and auto-stop.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(controller.state, RecorderState.idle);
    expect(controller.lastStopResult, isNotNull);
    expect(controller.lastStopResult!.stopReason, StopReason.maxDuration);
  });

  test('transcribeStoredRecording cuts a stored recording and transcribes it',
      () async {
    const id = 'offline-rec-1';
    await store.beginRecording(id);
    await store.appendChunk(id, _pcmChunk(11, _bytesPerSegment));
    await store.appendChunk(id, _pcmChunk(22, _bytesPerSegment));
    await store.finalizeRecording(id);

    final client = echoClient(handler: (request) async {
      final amplitude = ByteData.sublistView(request.bodyBytes, wavHeaderLength)
          .getInt16(0, Endian.little);
      return http.Response('{"text": "later$amplitude"}', 200);
    });
    final controller = buildController(client: client);

    final result = await controller.transcribeStoredRecording(id);

    expect(result.transcript, 'later11 later22');
    expect(result.failedSegments, isEmpty);
  });

  group('page-hide flush (web tab hidden/closed while recording)', () {
    // Regression test: RecorderController used to have no way of knowing
    // the browser tab might be closing, so a recording interrupted that
    // way was left in RecordingLifecycleState.recording for the next
    // launch's RecordingRecoveryService to patch up (best case) - the
    // reported symptom was that closing the tab a few seconds into a
    // recording sometimes left nothing recoverable at all. It now
    // registers a page-hide hook (a no-op on native/tests unless
    // injected, see page_lifecycle_hooks.dart) that finalizes the
    // recording immediately, the same way a normal stop() would.
    test('finalizes the recording instead of leaving it for next-launch recovery',
        () async {
      void Function()? capturedHook;
      var unsubscribeCalled = false;
      final controller = RecorderController(
        audioCapture: capture,
        fileStore: store,
        database: db,
        transcriptionClient: echoClient(),
        segmentDuration: _segmentDuration,
        backoff: (_) => Duration.zero,
        registerPageHideHook: (onMightBeClosing) {
          capturedHook = onMightBeClosing;
          return () => unsubscribeCalled = true;
        },
      );

      await controller.start();
      expect(capturedHook, isNotNull,
          reason: 'must register a page-hide hook while recording starts');

      // A chunk arrives and is durably appended (matching what real
      // browsers do: chunks land roughly every 100ms, so by the time any
      // hide/close event fires at least one has almost always already
      // been written) before the tab is hidden/closed.
      capture.emitChunk(_pcmChunk(77, _bytesPerSegment ~/ 2));
      await Future<void>.delayed(Duration.zero);

      final idle = Completer<void>();
      controller.addListener(() {
        if (controller.state == RecorderState.idle && !idle.isCompleted) {
          idle.complete();
        }
      });

      capturedHook!();
      await idle.future.timeout(const Duration(seconds: 5));

      expect(controller.state, RecorderState.idle);
      expect(controller.lastStopResult, isNotNull,
          reason: 'the recording must be fully finalized, not left dangling');
      expect(controller.lastStopResult!.attachedFile.size, greaterThan(wavHeaderLength));
      expect(unsubscribeCalled, isTrue,
          reason: 'must stop listening once the recording is no longer in progress');

      final recording = await db.getLocalRecording(controller.lastStopResult!.attachedFile.id);
      expect(recording?.state, RecordingLifecycleState.complete);
    });

    test('does nothing when not currently recording', () async {
      void Function()? capturedHook;
      final controller = RecorderController(
        audioCapture: capture,
        fileStore: store,
        database: db,
        transcriptionClient: echoClient(),
        segmentDuration: _segmentDuration,
        backoff: (_) => Duration.zero,
        registerPageHideHook: (onMightBeClosing) {
          capturedHook = onMightBeClosing;
          return () {};
        },
      );

      await controller.start();
      await controller.stop();
      expect(controller.state, RecorderState.idle);

      // Firing the (already unsubscribed, but simulate a late/duplicate
      // event anyway) hook once idle must not throw or call stop() again.
      expect(() => capturedHook?.call(), returnsNormally);
    });
  });
}
