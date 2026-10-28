// Thorough unit tests for RecorderController against fakes: ordering,
// retries, failure isolation, offline behaviour, the in-flight request
// limit, segment cutting, and that audio is stored completely even when
// every transcription request fails.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/services/interaction_feedback.dart';
import 'package:relationship_manager/services/app_settings_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/services/audio_capture.dart';
import 'package:relationship_manager/services/recorder_controller.dart';
import 'package:relationship_manager/services/sentence_segmenter.dart';
import 'package:relationship_manager/services/recording_file_store_native.dart';
import 'package:relationship_manager/services/recording_recovery_service.dart';
import 'package:relationship_manager/services/transcription_client.dart';
import 'package:relationship_manager/services/wav.dart';

import '../support/fake_audio_capture.dart';
import '../support/fake_speech_detector.dart';
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

class _PcmSpeechDetector extends EndingDetector {
  bool _detected = false;
  @override
  bool get hasSpeech => _detected;
  @override
  Future<bool> speechEnded(Uint8List frame) async {
    _detected |= frame.any((byte) => byte != 0);
    return false;
  }
  @override
  void reset({bool continuing = false}) => _detected = false;
}

class _TransientTextFailureDatabase extends DatabaseService {
  bool failNextTextSave = true;
  _TransientTextFailureDatabase(String path) : super(factory: databaseFactoryFfi, path: path);

  @override
  Future<void> saveRecordingSegmentText(String id, int sequence, int length, String text) async {
    if (failNextTextSave) {
      failNextTextSave = false;
      throw StateError('Transient text write failure');
    }
    await super.saveRecordingSegmentText(id, sequence, length, text);
  }
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
    InteractionFeedback? feedback,
    Future<SpeechDetector?> Function()? createSpeechDetector,
  }) {
    return RecorderController(
      audioCapture: capture,
      feedback: feedback,
      createSpeechDetector: createSpeechDetector ?? () async => EndingDetector(frames: 1000, minSpeechFrames: 1),
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
      httpClient: MockClient((request) async {
        if (request.method == 'GET') return http.Response('{}', 200);
        if (handler != null) return await handler(request);
        return http.Response(
              '{"text": "seg-${request.bodyBytes.length}"}', 200);
      }),
    );
  }

  test('successful original text is durable before stop and survives recovery without ASR', () async {
    var requests = 0;
    final controller = buildController(client: echoClient(handler: (_) async {
      requests++;
      return http.Response('{"text":"Original sentence."}', 200);
    }));
    final recognized = Completer<void>();
    controller.addListener(() {
      if (controller.liveTranscript == 'Original sentence.' && !recognized.isCompleted) recognized.complete();
    });
    await controller.start();
    capture.emitChunk(_pcmChunk(7, _bytesPerSegment));
    await recognized.future.timeout(const Duration(seconds: 5));
    final id = controller.recordingId!;
    expect(controller.state, RecorderState.recording);
    expect((await db.getRecordingTranscriptSlices(id))!.single.text, 'Original sentence.');
    controller.dispose();
    await RecordingRecoveryService(store, db).recoverIncompleteRecordings();
    var modelLoads = 0;
    final restarted = buildController(client: echoClient(handler: (_) async {
      fail('Recovered successful audio must never be recognized again');
    }), createSpeechDetector: () async { modelLoads++; return null; });
    final restored = await restarted.transcribeStoredRecording(id);
    expect(requests, 1);
    expect(modelLoads, 0);
    expect(restored.transcript, 'Original sentence.');
    expect(restored.transcriptSlices.single.startByte, 0);
    expect(restored.transcriptSlices.single.endByte, _bytesPerSegment);
  });

  test('retrying local persistence never recognizes the successful audio twice', () async {
    await (await db.database).close();
    db = _TransientTextFailureDatabase('${tempDir.path}/text-save.db');
    await db.initialize();
    var requests = 0;
    final controller = buildController(client: echoClient(handler: (_) async {
      requests++;
      return http.Response('{"text":"Paid original words."}', 200);
    }));
    await controller.start();
    capture.emitChunk(_pcmChunk(7, _bytesPerSegment));
    await Future<void>.delayed(Duration.zero);
    final result = await controller.stop();
    expect(requests, 1);
    expect(result.failedSegments, isEmpty);
    expect((await db.getRecordingTranscriptSlices(result.attachedFile.id))!.single.text, 'Paid original words.');
    await (await db.database).close();
  });

  test('stored retry recognizes only failed audio and preserves original successful words', () async {
    final controller = buildController(maxSegmentRetries: 0, client: echoClient(handler: (request) async {
      final sequence = request.url.queryParameters['segment'];
      return sequence == '1' ? http.Response('{}', 502)
          : http.Response('{"text":"original-$sequence"}', 200);
    }));
    await controller.start();
    for (var i = 0; i < 3; i++) {
      capture.emitChunk(_pcmChunk(7 + i, _bytesPerSegment));
    }
    await Future<void>.delayed(Duration.zero);
    final stopped = await controller.stop();
    expect(stopped.failedSegments.single.sequence, 1);
    final retries = <int>[];
    final restarted = buildController(client: echoClient(handler: (request) async {
      retries.add(int.parse(request.url.queryParameters['segment']!));
      expect(utf8.decode(base64Decode(request.headers['X-Transcription-Prompt']!)), 'original-0');
      return http.Response('{"text":"recovered-1"}', 200);
    }));
    final restored = await restarted.transcribeStoredRecording(stopped.attachedFile.id);
    expect(retries, [1]);
    expect(restored.transcript, 'original-0 recovered-1 original-2');
    expect(restored.transcriptSlices.map((slice) => slice.startByte), [0, 3200, 6400]);
    expect(restored.transcriptSlices.map((slice) => slice.text), ['original-0', 'recovered-1', 'original-2']);
  });

  test('prompt snapshots use completed contiguous preceding words without delaying concurrent jobs', () async {
    final first = Completer<http.Response>();
    final third = Completer<void>();
    final prefixReady = Completer<void>();
    final prompts = <String?>[];
    final controller = buildController(client: echoClient(handler: (request) async {
      final encoded = request.headers['X-Transcription-Prompt'];
      prompts.add(encoded == null ? null : utf8.decode(base64Decode(encoded)));
      final index = prompts.length - 1;
      if (index == 0) return first.future;
      if (index == 2) third.complete();
      return http.Response('{"text":"word$index"}', 200);
    }));
    controller.addListener(() {
      if (controller.liveTranscript == 'word0 word1 word2' && !prefixReady.isCompleted) prefixReady.complete();
    });
    await controller.start();
    for (var i = 0; i < 3; i++) {
      capture.emitChunk(_pcmChunk(7 + i, _bytesPerSegment));
    }
    await third.future.timeout(const Duration(seconds: 5));
    expect(prompts, [null, null, null], reason: 'future/out-of-order answers are not preceding context');
    first.complete(http.Response('{"text":"word0"}', 200));
    await prefixReady.future.timeout(const Duration(seconds: 5));
    capture.emitChunk(_pcmChunk(10, _bytesPerSegment));
    await Future<void>.delayed(Duration.zero);
    await controller.stop();
    expect(prompts.last, 'word0 word1 word2');
    await controller.start();
    capture.emitChunk(_pcmChunk(11, _bytesPerSegment));
    await Future<void>.delayed(Duration.zero);
    await controller.stop();
    expect(prompts.last, isNull, reason: 'another recording must not leak into the new prompt');
  });

  test('a retry keeps its prompt snapshot when preceding text completes later', () async {
    final first = Completer<http.Response>();
    final secondFailure = Completer<http.Response>();
    final secondStarted = Completer<void>();
    final prefixReady = Completer<void>();
    final prompts = <String?>[];
    final controller = buildController(client: echoClient(handler: (request) async {
      if (request.url.queryParameters['segment'] == '0') return first.future;
      prompts.add(request.headers['X-Transcription-Prompt']);
      if (prompts.length == 1) {
        secondStarted.complete();
        return secondFailure.future;
      }
      return http.Response('{"text":"second"}', 200);
    }));
    controller.addListener(() {
      if (controller.liveTranscript == 'first' && !prefixReady.isCompleted) prefixReady.complete();
    });
    await controller.start();
    capture.emitChunk(_pcmChunk(7, _bytesPerSegment));
    capture.emitChunk(_pcmChunk(8, _bytesPerSegment));
    await secondStarted.future.timeout(const Duration(seconds: 5));
    first.complete(http.Response('{"text":"first"}', 200));
    await prefixReady.future.timeout(const Duration(seconds: 5));
    secondFailure.complete(http.Response('{}', 502));
    expect((await controller.stop()).transcript, 'first second');
    expect(prompts, [null, null], reason: 'retry identity must preserve its original prompt');
  });

  test('feedback finishes before microphone capture and resumes only after stop', () async {
    final cues = <FeedbackCue>[];
    final settings = AppSettingsService()..soundsEnabled = true;
    final pendingStart = Completer<void>();
    final feedback = InteractionFeedback(settings,
      hapticPlayer: (_) async { expect(capture.isRecording, isFalse); },
      soundPlayer: (cue) async {
        expect(capture.isRecording, isFalse);
        cues.add(cue);
        if (cue == FeedbackCue.recordingStart) await pendingStart.future;
      },
    );
    final controller = buildController(client: echoClient(), feedback: feedback);
    final start = controller.start();
    await Future<void>.delayed(Duration.zero);
    expect(capture.isRecording, isFalse);
    expect(controller.state, RecorderState.requestingPermission);
    pendingStart.complete();
    await start;
    expect(capture.isRecording, isTrue);
    await feedback.play(FeedbackCue.success);
    expect(cues, [FeedbackCue.recordingStart]);
    capture.emitChunk(_pcmChunk(1000, 3200));
    await Future<void>.delayed(Duration.zero);
    await controller.stop();
    expect(cues, [FeedbackCue.recordingStart, FeedbackCue.recordingStop]);
    controller.dispose();
  });

  test('permission denial releases feedback suppression for retry', () async {
    final cues = <FeedbackCue>[];
    final feedback = InteractionFeedback(AppSettingsService(),
        hapticPlayer: (cue) async => cues.add(cue));
    capture.failureOnStart = AudioCaptureException(AudioCaptureFailureReason.permissionDenied, 'denied');
    final controller = buildController(client: echoClient(), feedback: feedback);
    await controller.start();
    expect(controller.state, RecorderState.failed);
    await feedback.play(FeedbackCue.selection);
    expect(cues, [FeedbackCue.recordingStart, FeedbackCue.error, FeedbackCue.selection]);
    controller.dispose();
  });

  test('silence and its final tail never upload, including after restart', () async {
    var requests = 0;
    final client = echoClient(handler: (_) async {
      requests++;
      return http.Response('{"text":"hallucination"}', 200);
    });
    final controller = buildController(client: client,
        segmentDuration: const Duration(seconds: 6),
        createSpeechDetector: () async => EndingDetector(detectsSpeech: false));
    final pcm = Uint8List(13 * 32000 + 718);
    await controller.start();
    capture.emitChunk(pcm);
    await Future<void>.delayed(Duration.zero);
    final result = await controller.stop();
    expect(requests, 0);
    expect(result.transcript, isEmpty);
    expect(result.failedSegments, isEmpty);
    final silentMarkers = AttachedFile.fromJson(result.attachedFile.toJson()).transcriptSlices;
    expect(silentMarkers, isNotEmpty, reason: 'synced/imported silence must remain known without ASR');
    expect(silentMarkers.every((slice) => slice.text.isEmpty), isTrue);
    expect(silentMarkers.first.startByte, 0);
    expect(silentMarkers.last.endByte, pcm.length);
    expect((await store.readBytes(result.attachedFile.id)).sublist(wavHeaderLength), pcm);
    final boundaries = await db.getRecordingSegments(result.attachedFile.id);
    expect(boundaries, isNotEmpty);
    expect(boundaries.every((boundary) => boundary.hasSpeech == false), isTrue);
    expect(boundaries.fold<int>(0, (sum, boundary) => sum + boundary.length), pcm.length);
    final restarted = buildController(client: client, createSpeechDetector: () async => null);
    final retry = await restarted.transcribeStoredRecording(result.attachedFile.id);
    expect(retry.transcript, isEmpty);
    expect(retry.failedSegments, isEmpty);
    expect(requests, 0);
  });

  test('skipped silence preserves speech bytes and sequence on retry', () async {
    final uploads = <({String sequence, Uint8List bytes})>[];
    final client = echoClient(handler: (request) async {
      uploads.add((sequence: request.url.queryParameters['segment']!, bytes: request.bodyBytes));
      return http.Response('{"text":"spoken words"}', 200);
    });
    final controller = buildController(client: client,
        segmentDuration: const Duration(seconds: 6),
        createSpeechDetector: () async => _PcmSpeechDetector());
    final pcm = Uint8List.fromList([
      ...Uint8List(6 * 32000), ..._pcmChunk(1000, 3 * 32000), ...Uint8List(8 * 32000),
    ]);
    await controller.start();
    capture.emitChunk(pcm);
    await Future<void>.delayed(Duration.zero);
    final result = await controller.stop();
    expect(uploads, hasLength(1));
    expect(uploads.single.sequence, '1');
    expect(result.transcript, 'spoken words');
    final slice = result.attachedFile.transcriptSlices.singleWhere((slice) => slice.text.isNotEmpty);
    expect(slice.startByte, 5 * 32000); // Quiet-cut fallback retains one second.
    expect(slice.endByte, slice.startByte + uploads.single.bytes.length - wavHeaderLength);
    expect(slice.text, 'spoken words');
    expect((await store.readBytes(result.attachedFile.id)).sublist(wavHeaderLength), pcm);
    final restarted = buildController(client: client, createSpeechDetector: () async => null);
    final retried = await restarted.transcribeStoredRecording(result.attachedFile.id);
    final retriedSpeech = retried.transcriptSlices.singleWhere((slice) => slice.text.isNotEmpty);
    expect(retriedSpeech.startByte, slice.startByte);
    expect(retriedSpeech.endByte, slice.endByte);
    expect(retriedSpeech.text, slice.text);
    expect(uploads, hasLength(1), reason: 'successful original audio must not be recognized again');
  });

  test('unavailable VAD keeps audio retryable without sending unclassified bytes', () async {
    final uploads = <Uint8List>[];
    final client = echoClient(handler: (request) async {
      uploads.add(request.bodyBytes);
      return http.Response('{"text":"recovered speech"}', 200);
    });
    final controller = buildController(client: client,
        segmentDuration: const Duration(seconds: 6), createSpeechDetector: () async => null);
    final pcm = _pcmChunk(1000, 3 * 32000);
    await controller.start();
    capture.emitChunk(pcm);
    await Future<void>.delayed(Duration.zero);
    final result = await controller.stop();
    expect(uploads, isEmpty);
    expect(result.failedSegments, hasLength(1));
    expect(controller.liveTranscriptionReason, LiveTranscriptionReason.failing);
    expect((await db.getRecordingSegments(result.attachedFile.id)).single.hasSpeech, isNull);
    expect((await store.readBytes(result.attachedFile.id)).sublist(wavHeaderLength), pcm);
    final restarted = buildController(client: client,
        createSpeechDetector: () async => EndingDetector());
    final retry = await restarted.transcribeStoredRecording(result.attachedFile.id);
    expect(retry.transcript, 'recovered speech');
    expect(retry.failedSegments, isEmpty);
    expect(uploads, hasLength(1));
    expect(uploads.single.sublist(wavHeaderLength), pcm);
    expect((await db.getRecordingSegments(result.attachedFile.id)).single.hasSpeech, isTrue);
  });

  test('legacy silence is classified locally before any upload', () async {
    await store.beginRecording('legacy-silence', format: WavFormat.standard);
    await store.appendChunk('legacy-silence', Uint8List(7 * 32000));
    await store.finalizeRecording('legacy-silence', format: WavFormat.standard);
    var requests = 0;
    final controller = buildController(
        client: echoClient(handler: (_) async {
          requests++;
          return http.Response('{"text":"hallucination"}', 200);
        }),
        segmentDuration: const Duration(seconds: 6),
        createSpeechDetector: () async => EndingDetector(detectsSpeech: false));
    final result = await controller.transcribeStoredRecording('legacy-silence');
    expect(requests, 0);
    expect(result.transcript, isEmpty);
    expect(result.failedSegments, isEmpty);
    expect((await db.getRecordingSegments('legacy-silence')).every((b) => b.hasSpeech == false), isTrue);
  });

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

  test('continuous speech starts transcription after six seconds', () async {
    final requested = Completer<void>();
    final controller = RecorderController(
      audioCapture: capture,
      createSpeechDetector: () async => EndingDetector(frames: 1000, minSpeechFrames: 1),
      fileStore: store,
      database: db,
      transcriptionClient: echoClient(handler: (request) async {
        if (!requested.isCompleted) requested.complete();
        return http.Response('{"text":"early words"}', 200);
      }),
    );
    await controller.start();
    capture.emitChunk(_pcmChunk(7, 5 * 32000));
    await Future<void>.delayed(Duration.zero);
    expect(requested.isCompleted, isFalse);
    expect(controller.isTranscribing, isFalse);

    capture.emitChunk(_pcmChunk(7, 32000));
    await requested.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(Duration.zero);
    expect(controller.state, RecorderState.recording);
    expect(controller.liveTranscript, 'early words');
    expect(controller.isTranscribing, isFalse);
    final result = await controller.stop();
    expect(result.transcript, contains('early words'));
    expect(result.attachedFile.durationMs, 6000);
  });

  test('VAD cuts live utterances and persisted retries retain exact identities after restart', () async {
    final liveBodies = <Uint8List>[];
    final retryBodies = <Uint8List>[];
    final requested = Completer<void>();
    final controller = RecorderController(
      audioCapture: capture,
      fileStore: store,
      database: db,
      createSpeechDetector: () async => EndingDetector(),
      transcriptionClient: echoClient(handler: (request) async {
        final lengths = await db.getRecordingSegments(request.url.queryParameters['recordingId']!);
        expect(lengths, isNotEmpty, reason: 'boundary must precede HTTP submission');
        liveBodies.add(request.bodyBytes);
        if (!requested.isCompleted) requested.complete();
        return http.Response('{"text":"sentence"}', 200);
      }),
    );
    await controller.start();
    capture.emitChunk(_pcmChunk(7, 3 * 32000));
    await requested.future.timeout(const Duration(seconds: 5));
    expect(controller.state, RecorderState.recording);
    expect(liveBodies.first.length, wavHeaderLength + 48 * 1024);
    final result = await controller.stop();
    await db.clearAllData(); // Retained audio keeps its original boundaries.
    final restarted = buildController(createSpeechDetector: () async => null, client: echoClient(handler: (request) async {
      retryBodies.add(request.bodyBytes);
      return http.Response('{"text":"retried"}', 200);
    })); // VAD unavailable and a different configured fallback after restart.
    await restarted.transcribeStoredRecording(result.attachedFile.id);
    expect(retryBodies, isEmpty);
    await db.deleteRecordingPermanently(result.attachedFile.id, store);
    expect(await db.getRecordingSegments(result.attachedFile.id), isEmpty);
  });

  test('processing stays visible for queued requests and final partial audio', () async {
    final responses = List.generate(4, (_) => Completer<http.Response>());
    final started = List.generate(4, (_) => Completer<void>());
    var requests = 0;
    final controller = buildController(client: echoClient(handler: (request) {
      final index = requests++;
      started[index].complete();
      return responses[index].future;
    }));
    final processing = <bool>[];
    controller.addListener(() => processing.add(controller.isTranscribing));
    expect(controller.isTranscribing, isFalse);
    await controller.start();
    for (var i = 0; i < 3; i++) {
      capture.emitChunk(_pcmChunk(7, _bytesPerSegment));
    }
    capture.emitChunk(_pcmChunk(7, _bytesPerSegment ~/ 2));
    await started[1].future.timeout(const Duration(seconds: 5));
    final stopped = controller.stop();
    expect(controller.state, RecorderState.finishing);
    expect(controller.isTranscribing, isTrue);

    responses[1].complete(http.Response('{"text":"second"}', 200));
    await started[2].future.timeout(const Duration(seconds: 5));
    expect(controller.liveTranscript, isEmpty);
    expect(controller.isTranscribing, isTrue);
    responses[0].complete(http.Response('{"text":"first"}', 200));
    await started[3].future.timeout(const Duration(seconds: 5));
    expect(controller.isTranscribing, isTrue);
    responses[2].complete(http.Response('{"text":"third"}', 200));
    responses[3].complete(http.Response('{"text":"tail"}', 200));
    expect((await stopped).transcript, 'first second third tail');
    expect(controller.isTranscribing, isFalse);
    expect(processing, contains(true));
    expect(processing.last, isFalse);
  });

  test('processing remains visible while waiting to retry', () async {
    var attempts = 0;
    final retryStarted = Completer<void>();
    final response = Completer<http.Response>();
    late RecorderController controller;
    controller = RecorderController(
      audioCapture: capture,
      createSpeechDetector: () async => EndingDetector(frames: 1000, minSpeechFrames: 1),
      fileStore: store,
      database: db,
      transcriptionClient: echoClient(handler: (request) async {
        if (attempts++ == 0) {
          return http.Response('{"slug":"transcription_failed"}', 502);
        }
        retryStarted.complete();
        return response.future;
      }),
      segmentDuration: _segmentDuration,
      backoff: (_) {
        expect(controller.isTranscribing, isTrue);
        expect(controller.liveTranscriptionReason, LiveTranscriptionReason.failing);
        return Duration.zero;
      },
    );
    await controller.start();
    capture.emitChunk(_pcmChunk(7, _bytesPerSegment));
    await retryStarted.future.timeout(const Duration(seconds: 5));
    expect(controller.isTranscribing, isTrue);
    response.complete(http.Response('{"text":"retried"}', 200));
    expect((await controller.stop()).transcript, 'retried');
    expect(controller.isTranscribing, isFalse);
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
    expect(controller.liveTranscript, '',
        reason:
            'live text must remain an append-only prefix while earlier segments are pending');

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
    expect(result.attachedFile.transcriptSlices.single.startByte, _bytesPerSegment);
    expect(result.attachedFile.transcriptSlices.single.endByte, _bytesPerSegment * 2);
    expect(result.attachedFile.transcriptSlices.single.text, 'good42');
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
    expect(controller.isTranscribing, isFalse);
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
    expect(controller.liveTranscriptionReason, LiveTranscriptionReason.offline);
    capture.emitChunk(_pcmChunk(7, _bytesPerSegment));
    await Future<void>.delayed(Duration.zero);

    final result = await controller.stop();

    expect(controller.liveTranscriptionReason, LiveTranscriptionReason.offline);
    expect(result.failedSegments, hasLength(1));
    expect(result.attachedFile.size, wavHeaderLength + _bytesPerSegment);
  });

  test('anonymous recording transcribes without a preemptive sign-in failure', () async {
    final anonymousClient = TranscriptionClient(
      baseUrl: 'https://api.example.com', getToken: () => null,
      httpClient: MockClient((request) async => http.Response('{"text":"guest"}', 200)),
    );
    final controller = buildController(client: anonymousClient, maxSegmentRetries: 0);
    await controller.start();
    expect(controller.liveTranscriptionReason, LiveTranscriptionReason.notStarted);
    expect(controller.isAnonymousRecording, isTrue);
    expect(controller.effectiveMaxDuration, const Duration(hours: 2));
    capture.emitChunk(_pcmChunk(7, _bytesPerSegment));
    await Future<void>.delayed(Duration.zero);
    final result = await controller.stop();
    expect(controller.liveTranscriptionReason, LiveTranscriptionReason.working);
    expect(result.transcript, 'guest');
  });

  test('silence beyond one minute does not consume transcription allowance or truncate audio',
      () async {
    var uploads = 0;
    final controller = RecorderController(
      audioCapture: capture,
      createSpeechDetector: () async => _PcmSpeechDetector(),
      fileStore: store,
      database: db,
      transcriptionClient: TranscriptionClient(
        baseUrl: 'https://api.example.com',
        getToken: () => null,
        httpClient: MockClient((request) async {
          if (request.method == 'POST') uploads++;
          return http.Response(
              jsonEncode({
                'text': '',
                'usedSeconds': 0,
                'remainingSeconds': 300,
                'dailyLimitSeconds': 300,
                'resetAt': '2050-01-01T00:00:00Z'
              }),
              200);
        }),
      ),
    );
    addTearDown(controller.dispose);
    await controller.start();
    capture.emitChunk(Uint8List(61 * 32000));
    await Future<void>.delayed(Duration.zero);
    expect(controller.state, RecorderState.recording);
    final result = await controller.stop();
    expect(result.stopReason, StopReason.user);
    expect(result.attachedFile.durationMs, 61000);
    expect(result.attachedFile.size, wavHeaderLength + 61 * 32000);
    expect(uploads, 0);
    expect(controller.transcribedSeconds, 0);
    expect(controller.showGuestTranscriptionWarning, isFalse);
  });

  for (final authenticated in [false, true]) {
    test(
        'cumulative ${authenticated ? 'signed-in' : 'guest'} speech allowance stops capture without losing original', () async {
    final limit = authenticated ? 1200 : 300;
    final controller = RecorderController(
      audioCapture: capture,
      createSpeechDetector: () async => EndingDetector(frames: 1000, minSpeechFrames: 1),
      fileStore: store,
      database: db,
      transcriptionClient: TranscriptionClient(
        baseUrl: 'https://api.example.com', getToken: () => authenticated ? 'token' : null,
        httpClient: MockClient((request) async => http.Response(jsonEncode({
                'text': 'Final spoken sentence',
                'usedSeconds': request.method == 'GET' ? limit - 6 : limit,
                'remainingSeconds': request.method == 'GET' ? 6 : 0,
                'dailyLimitSeconds': limit,
                'resetAt': '2050-01-01T00:00:00Z',
              }), 200)),
      ),
    );
      addTearDown(controller.dispose);
    final stopped = Completer<void>();
    controller.addListener(() {
      if (controller.lastStopResult != null && !stopped.isCompleted) stopped.complete();
    });
    await controller.start();
    capture.emitChunk(_pcmChunk(7, 6 * 32000));
    await stopped.future.timeout(const Duration(seconds: 10));
    final result = controller.lastStopResult!;
    expect(result.stopReason, authenticated ? StopReason.dailyLimit : StopReason.anonymousLimit);
      expect(result.transcript, 'Final spoken sentence');
    expect(result.attachedFile.durationMs, 6000);
    expect(await store.exists(result.attachedFile.id), isTrue);
    expect(controller.transcribedSeconds, limit);
    expect(controller.showGuestTranscriptionWarning, !authenticated);
  });

  }

  test('exhausted guest allowance blocks microphone and clears previous stop result', () async {
    var remaining = 6;
    final controller = buildController(client: TranscriptionClient(
      baseUrl: 'https://api.example.com', getToken: () => null,
      httpClient: MockClient((request) async => http.Response(
          request.method == 'GET' ? jsonEncode({
                  'usedSeconds': 300 - remaining,
                  'remainingSeconds': remaining,
                  'dailyLimitSeconds': 300,
                  'resetAt': '2050-01-01T00:00:00Z'
                })
              : '{"text":"guest"}', 200)),
    ));
    await controller.start();
    await controller.stop();
    expect(controller.lastStopResult, isNotNull);
    capture.failureOnStart = AudioCaptureException(
        AudioCaptureFailureReason.permissionDenied, 'Microphone must not be requested');
    remaining = 0;
    await controller.start();
    expect(capture.isRecording, isFalse);
    expect(controller.failure, isNull);
    expect(controller.lastStopResult, isNull);
    expect(controller.state, RecorderState.idle);
    expect(controller.liveTranscriptionReason, LiveTranscriptionReason.anonymousLimit);
  });

  test('segments and retries share one recording identity', () async {
    final requests = <Map<String, String>>[];
    final controller = buildController(client: echoClient(handler: (request) async {
      requests.add(request.url.queryParameters);
      if (requests.length == 1) return http.Response('{"slug":"transcription_failed"}', 502);
      return http.Response('{"text":"ok"}', 200);
    }));
    await controller.start();
    capture.emitChunk(_pcmChunk(7, _bytesPerSegment));
    capture.emitChunk(_pcmChunk(8, _bytesPerSegment));
    await Future<void>.delayed(Duration.zero);
    final result = await controller.stop();
    expect(requests.map((r) => r['recordingId']).toSet(), {result.attachedFile.id});
    expect(requests.where((r) => r['segment'] == '0'), hasLength(2));
    expect(requests.where((r) => r['segment'] == '1'), hasLength(1));
  });

  for (final status in [401, 413, 415, 503]) {
    test('permanent transcription failure $status does not retry or lose audio', () async {
      var requests = 0;
      final controller = buildController(client: echoClient(handler: (request) async {
        requests++;
        return http.Response('{"slug":"transcription_not_configured"}', status);
      }));
      await controller.start();
      capture.emitChunk(_pcmChunk(7, _bytesPerSegment));
      await Future<void>.delayed(Duration.zero);
      final result = await controller.stop();
      expect(requests, 1);
      expect(result.failedSegments, hasLength(1));
      expect(await store.exists(result.attachedFile.id), isTrue);
    });
  }

  test('anonymous quota exhaustion does not retry and asks for sign-in', () async {
    var requests = 0;
    final controller = buildController(client: TranscriptionClient(
      baseUrl: 'https://api.example.com', getToken: () => null,
      httpClient: MockClient((request) async {
        if (request.method == 'GET') return http.Response('{"remainingRecordings":3}', 200);
        requests++;
        return http.Response('{"slug":"anonymous_daily_limit"}', 429);
      }),
    ));
    await controller.start();
    capture.emitChunk(_pcmChunk(7, _bytesPerSegment));
    await Future<void>.delayed(Duration.zero);
    final result = await controller.stop();
    expect(requests, 1);
    expect(controller.liveTranscriptionReason, LiveTranscriptionReason.anonymousLimit);
    expect(result.failedSegments, hasLength(1));
    expect(await store.exists(result.attachedFile.id), isTrue);
  });

  test('at most 2 transcription requests are in flight at once', () async {
    var active = 0;
    var maxActive = 0;
    final release = Completer<void>();
    final saturated = Completer<void>();
    final controller = buildController(
      client: echoClient(handler: (request) async {
        active++;
        maxActive = active > maxActive ? active : maxActive;
        if (active == 2 && !saturated.isCompleted) saturated.complete();
        await release.future;
        active--;
        return http.Response('{"text": "ok"}', 200);
      }),
    );

    await controller.start();
    // Cut four segments in quick succession.
    for (var i = 0; i < 4; i++) {
      capture.emitChunk(_pcmChunk(10 + i, _bytesPerSegment));
    }
    await saturated.future.timeout(const Duration(seconds: 5));

    expect(maxActive, lessThanOrEqualTo(2));
    expect(active, 2); // exactly the concurrency limit should be in flight

    // Release them all so stop() can finish.
    release.complete();

    final result = await controller.stop();
    expect(result.failedSegments, isEmpty);
    expect(maxActive, 2);
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

  test('stored retry keeps live segment identity after an oversized microphone chunk', () async {
    final liveBodies = <Uint8List>[];
    final retryBodies = <Uint8List>[];
    var retry = false;
    final controller = buildController(client: echoClient(handler: (request) async {
      (retry ? retryBodies : liveBodies).add(Uint8List.fromList(request.bodyBytes));
      return retry ? http.Response('{"text":"ok"}', 200) : http.Response('{}', 502);
    }), maxSegmentRetries: 0);
    await controller.start();
    capture.emitChunk(_pcmChunk(7, 3600));
    await Future<void>.delayed(Duration.zero);
    final stopped = await controller.stop();
    retry = true;
    await controller.transcribeStoredRecording(stopped.attachedFile.id);
    expect(retryBodies, liveBodies);
  });

  test('stored retry keeps live segment identity at an exact six-second quiet-cut boundary', () async {
    final liveBodies = <Uint8List>[];
    final retryBodies = <Uint8List>[];
    var retry = false;
    final controller = buildController(client: echoClient(handler: (request) async {
      (retry ? retryBodies : liveBodies).add(Uint8List.fromList(request.bodyBytes));
      return retry ? http.Response('{"text":"ok"}', 200) : http.Response('{}', 502);
    }), segmentDuration: const Duration(seconds: 6), maxSegmentRetries: 0);
    await controller.start();
    capture.emitChunk(_pcmChunk(7, 192000));
    await Future<void>.delayed(Duration.zero);
    final stopped = await controller.stop();
    retry = true;
    await controller.transcribeStoredRecording(stopped.attachedFile.id);
    expect(retryBodies, liveBodies);
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
      createSpeechDetector: () async => EndingDetector(frames: 1000, minSpeechFrames: 1),
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
      createSpeechDetector: () async => EndingDetector(frames: 1000, minSpeechFrames: 1),
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
