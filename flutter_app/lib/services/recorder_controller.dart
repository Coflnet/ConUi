import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/models.dart';
import 'audio_capture.dart';
import 'database_service.dart';
import 'interaction_feedback.dart';
import 'page_lifecycle_hooks.dart';
import 'recording_file_store.dart';
import 'sentence_segmenter.dart';
import 'transcription_client.dart';
import 'wav.dart';

enum RecorderState { idle, requestingPermission, recording, finishing, failed }

/// Why the live transcript isn't updating right now (or that it is).
/// Deliberately an enum, not a string - the UI (step 8+) is responsible for
/// turning this into user-facing text.
enum LiveTranscriptionReason {
  /// Nothing has happened yet (no segment attempted).
  notStarted,

  /// The most recent segment transcribed successfully.
  working,

  offline,
  notSignedIn,
  notConfigured,
  anonymousLimit,

  /// Segments keep failing for some other reason (rate limited, backend
  /// error, unsupported audio, ...).
  failing,
}

LiveTranscriptionReason _reasonFor(TranscriptionErrorKind kind) {
  switch (kind) {
    case TranscriptionErrorKind.offline:
      return LiveTranscriptionReason.offline;
    case TranscriptionErrorKind.unauthorized:
      return LiveTranscriptionReason.notSignedIn;
    case TranscriptionErrorKind.anonymousLimit:
      return LiveTranscriptionReason.anonymousLimit;
    case TranscriptionErrorKind.notConfigured:
      return LiveTranscriptionReason.notConfigured;
    case TranscriptionErrorKind.payloadTooLarge:
    case TranscriptionErrorKind.unsupportedMedia:
    case TranscriptionErrorKind.rateLimited:
    case TranscriptionErrorKind.transcriptionFailed:
    case TranscriptionErrorKind.other:
      return LiveTranscriptionReason.failing;
  }
}

/// One transcription unit: a slice of PCM audio with a sequence number so
/// the transcript can always be reassembled in order even if the backend's
/// answers arrive out of order.
class TranscriptSegment {
  final int sequence;
  final Uint8List pcmBytes;
  /// Null when speech detection was unavailable; these bytes remain retryable.
  final bool? hasSpeech;

  /// Null until a transcription attempt succeeds.
  String? text;

  /// True once every retry has been exhausted without success.
  bool failed = false;

  int attempts = 0;

  TranscriptSegment({required this.sequence, required this.pcmBytes, this.hasSpeech});
}

enum StopReason { user, maxDuration, anonymousLimit }

/// Everything a caller needs after a recording stops: the file to attach to
/// an Event, the transcript assembled so far, and which segments (if any)
/// never got transcribed.
class RecorderStopResult {
  final AttachedFile attachedFile;
  final String transcript;
  final List<TranscriptSegment> failedSegments;
  final StopReason stopReason;

  const RecorderStopResult({
    required this.attachedFile,
    required this.transcript,
    required this.failedSegments,
    required this.stopReason,
  });
}

class TranscribeLaterResult {
  final String transcript;
  final List<TranscriptSegment> failedSegments;
  final List<RecordingTranscriptSlice> transcriptSlices;

  const TranscribeLaterResult({
    required this.transcript,
    required this.failedSegments,
    this.transcriptSlices = const [],
  });
}

List<RecordingTranscriptSlice> _transcriptSlices(List<TranscriptSegment> segments) {
  final slices = <RecordingTranscriptSlice>[];
  var offset = 0;
  for (final segment in segments) {
    final start = offset;
    offset += segment.pcmBytes.length;
    final text = segment.text?.trim() ?? '';
    if (segment.text != null) {
      slices.add(RecordingTranscriptSlice(startByte: start, endByte: offset, text: text));
    }
  }
  return slices;
}

/// Drives one recording end to end: microphone capture, durable local
/// storage of every chunk (crash safety), cutting segments at VAD speech ends
/// (with a [segmentDuration] quiet-cut fallback) and sending them for live transcription (at
/// most [maxConcurrentRequests] in flight, retried with backoff, never
/// blocking the recording), and producing the final [AttachedFile] +
/// transcript on [stop].
///
/// UI code drives this with one call to [start] and one to [stop] and
/// listens via [ChangeNotifier] for [state], [elapsed], [inputLevel],
/// [liveTranscript] and [liveTranscriptionReason].
class RecorderController extends ChangeNotifier {
  final AudioCapture _audioCapture;
  final RecordingFileStore _fileStore;
  RecordingFileStore get fileStore => _fileStore;
  final DatabaseService _db;
  final TranscriptionClient _transcriptionClient;
  final WavFormat format;
  final Duration segmentDuration;
  final Future<SpeechDetector?> Function() createSpeechDetector;
  final Duration maxDuration;
  final int maxSegmentRetries;
  final int maxConcurrentRequests;
  final String? language;
  final InteractionFeedback? feedback;
  bool _feedbackCapture = false;
  bool _disposed = false;
  bool _canRetryStop = false;
  bool get canRetryStop => _canRetryStop;
  final Duration Function(int attempt) backoff;
  final PageLifecycleUnsubscribe Function(void Function() onMightBeClosing)
      _registerPageHideHook;

  RecorderController({
    required AudioCapture audioCapture,
    required RecordingFileStore fileStore,
    required DatabaseService database,
    required TranscriptionClient transcriptionClient,
    this.format = WavFormat.standard,
    this.segmentDuration = const Duration(seconds: 6),
    this.createSpeechDetector = DiaSpeechDetector.create,
    this.maxDuration = const Duration(hours: 2),
    this.maxSegmentRetries = 3,
    this.maxConcurrentRequests = 2,
    this.language,
    this.feedback,
    Duration Function(int attempt)? backoff,
    // Overridable for tests; defaults to the real platform hook (a no-op
    // everywhere except web - see page_lifecycle_hooks.dart).
    PageLifecycleUnsubscribe Function(void Function() onMightBeClosing)?
        registerPageHideHook,
  })  : _audioCapture = audioCapture,
        _fileStore = fileStore,
        _db = database,
        _transcriptionClient = transcriptionClient,
        backoff = backoff ?? _defaultBackoff,
        _registerPageHideHook = registerPageHideHook ?? onPageMightBeClosing;

  static Duration _defaultBackoff(int attempt) {
    final factor = 1 << (attempt - 1).clamp(0, 4); // 1,2,4,8,16
    return Duration(milliseconds: 500 * factor);
  }

  RecorderState _state = RecorderState.idle;
  RecorderState get state => _state;

  AudioCaptureException? _failure;
  AudioCaptureException? get failure => _failure;

  String? _recordingId;
  String? get recordingId => _recordingId;

  DateTime? _startedAt;
  Duration _elapsed = Duration.zero;
  Duration get elapsed => _elapsed;

  double _inputLevel = 0.0;
  double get inputLevel => _inputLevel;

  LiveTranscriptionReason _liveTranscriptionReason =
      LiveTranscriptionReason.notStarted;
  LiveTranscriptionReason get liveTranscriptionReason =>
      _liveTranscriptionReason;
  bool get isLiveTranscriptionWorking =>
      _liveTranscriptionReason == LiveTranscriptionReason.working;

  final List<TranscriptSegment> _segments = [];
  List<TranscriptSegment> get segments => List.unmodifiable(_segments);
  /// Whether live segments are queued, in flight, or waiting for a retry.
  bool get isTranscribing =>
      _segments.any((segment) => segment.text == null && !segment.failed);
  int _nextSequence = 0;

  /// An append-only prefix: later answers wait for earlier segments to
  /// succeed or exhaust their retries before becoming visible.
  String get liveTranscript {
    final sorted = [..._segments]
      ..sort((a, b) => a.sequence.compareTo(b.sequence));
    return sorted
        .takeWhile((s) => s.text != null || s.failed)
        .map((s) => s.text ?? '')
        .where((t) => t.isNotEmpty)
        .join(' ')
        .trim();
  }

  SentenceSegmenter? _segmenter;
  Future<void> _appendChain = Future.value();

  StreamSubscription<Uint8List>? _chunkSubscription;
  StreamSubscription<double>? _amplitudeSubscription;
  Timer? _ticker;
  bool _autoStopping = false;
  bool _anonymousRecording = false;
  int _recordedPcmBytes = 0;
  static const anonymousMaxDuration = Duration(minutes: 1);
  bool get isAnonymousRecording => _state == RecorderState.idle || _state == RecorderState.failed
      ? _transcriptionClient.getToken() == null : _anonymousRecording;
  Duration get effectiveMaxDuration => _anonymousRecording && maxDuration > anonymousMaxDuration
      ? anonymousMaxDuration : maxDuration;
  PageLifecycleUnsubscribe? _pageHideUnsubscribe;

  final Queue<TranscriptSegment> _pendingQueue = Queue();
  final Set<Future<void>> _activeJobs = {};

  /// The most recent [RecorderStopResult], whether [stop] was called
  /// directly or triggered automatically by hitting [maxDuration]. Useful
  /// for observing an auto-stop, whose Future isn't awaited by anyone.
  RecorderStopResult? _lastStopResult;
  RecorderStopResult? get lastStopResult => _lastStopResult;

  /// Starts requesting the microphone and, on success, starts recording.
  /// On failure, [state] becomes [RecorderState.failed] and [failure]
  /// explains why (permission denied / no microphone / other) - it never
  /// throws.
  Future<void> start() async {
    if (_disposed || _canRetryStop ||
        _state == RecorderState.finishing ||
        _state == RecorderState.recording ||
        _state == RecorderState.requestingPermission) {
      return;
    }

    _state = RecorderState.requestingPermission;
    _failure = null;
    _lastStopResult = null;
    _anonymousRecording = _transcriptionClient.getToken() == null;
    notifyListeners();
    if (_anonymousRecording &&
        await _transcriptionClient.remainingAnonymousRecordings() == 0) {
      _liveTranscriptionReason = LiveTranscriptionReason.anonymousLimit;
      _state = RecorderState.idle;
      notifyListeners();
      return;
    }

    final Stream<Uint8List> chunkStream;
    try {
      _feedbackCapture = feedback != null;
      await feedback?.beginRecording();
      if (_disposed) {
        await _endFeedback(silent: true);
        return;
      }
      chunkStream = await _audioCapture.start(format: format);
      if (_disposed) {
        await _audioCapture.stop();
        await _endFeedback(silent: true);
        return;
      }
    } catch (e) {
      await _endFeedback(failed: true);
      _failure = e is AudioCaptureException
          ? e
          : AudioCaptureException(AudioCaptureFailureReason.other, '$e');
      _state = RecorderState.failed;
      notifyListeners();
      return;
    }

    _recordingId = const Uuid().v4();
    _segments.clear();
    _pendingQueue.clear();
    _activeJobs.clear();
    _nextSequence = 0;
    final segmenter = SentenceSegmenter(
      format: format,
      maxDuration: segmentDuration,
      onSegment: _enqueueSegment,
    );
    _segmenter = segmenter;
    // Keep capture durable while the model loads. Unclassified segments stay
    // saved for retry rather than being sent without a speech check.
    unawaited(_attachSpeechDetector(segmenter));
    _appendChain = Future.value();
    _recordedPcmBytes = 0;
    _liveTranscriptionReason = !_transcriptionClient.isConfigured
        ? LiveTranscriptionReason.offline
        : LiveTranscriptionReason.notStarted;
    _elapsed = Duration.zero;
    _startedAt = DateTime.now();
    _autoStopping = false;

    try {
      await _fileStore.beginRecording(_recordingId!, format: format);
      await _db.saveLocalRecording(LocalRecordingState(
        id: _recordingId!,
        state: RecordingLifecycleState.recording,
      ));
    } catch (e) {
      await _audioCapture.stop();
      await _endFeedback(failed: true);
      _failure = AudioCaptureException(AudioCaptureFailureReason.other, '$e');
      _state = RecorderState.failed;
      notifyListeners();
      return;
    }

    if (_disposed) return;
    _state = RecorderState.recording;
    notifyListeners();

    _chunkSubscription = chunkStream.listen(_onChunk);
    _amplitudeSubscription = _audioCapture.amplitudeStream.listen((level) {
      _inputLevel = level;
      notifyListeners();
    });
    _ticker =
        Timer.periodic(const Duration(milliseconds: 200), (_) => _onTick());
    // On web, catches the tab being hidden/closed while recording so the
    // recording gets finalized now (state -> complete) rather than left
    // for RecordingRecoveryService to patch up (state -> recovered) at
    // the next launch - see _onPageMightBeClosing.
    _pageHideUnsubscribe = _registerPageHideHook(_onPageMightBeClosing);
  }

  /// Best effort: a synchronous browser event handler can't await
  /// anything, and on an actual tab close there's no guarantee this
  /// finishes either way - but every chunk already durable (everything
  /// appended so far, see [_handleChunk]) is safe regardless, and this
  /// gives the rest (the trailing partial segment, the row's state, the
  /// WAV header) a real chance to be finalized properly before the page
  /// actually unloads, instead of relying solely on next-launch recovery.
  void _onPageMightBeClosing() {
    if (_state == RecorderState.recording) {
      unawaited(stop());
    }
  }

  void _onTick() {
    if (_startedAt == null) return;
    _elapsed = DateTime.now().difference(_startedAt!);
    notifyListeners();
    if (!_autoStopping && _elapsed >= effectiveMaxDuration) {
      _autoStopping = true;
      unawaited(stop(reason: _anonymousRecording && effectiveMaxDuration == anonymousMaxDuration
          ? StopReason.anonymousLimit : StopReason.maxDuration));
    }
  }

  void _onChunk(Uint8List chunk) {
    _appendChain = _appendChain.then((_) => _handleChunk(chunk));
  }

  Future<void> _handleChunk(Uint8List chunk) async {
    // Crash safety first: the byte is durable before anything else happens
    // to it. Transcription problems below never affect this.
    final byteLimit = anonymousMaxDuration.inSeconds * format.bytesPerSecond;
    if (_anonymousRecording) {
      final remaining = (byteLimit - _recordedPcmBytes).clamp(0, byteLimit);
      if (chunk.length > remaining) chunk = Uint8List.sublistView(chunk, 0, remaining);
    }
    await _fileStore.appendChunk(_recordingId!, chunk);
    _recordedPcmBytes += chunk.length;
    await _segmenter!.add(chunk);
    if (_anonymousRecording && !_autoStopping && _recordedPcmBytes >= byteLimit) {
      _autoStopping = true;
      unawaited(stop(reason: StopReason.anonymousLimit));
    }
  }

  Future<void> _attachSpeechDetector(SentenceSegmenter segmenter) async {
    try {
      await segmenter.attachDetector(await createSpeechDetector());
    } catch (_) {
      // Capture stays available; unclassified audio is kept for a later retry.
    }
  }

  void _enqueueSegment(Uint8List segmentBytes, bool? hasSpeech) {
    final job = TranscriptSegment(sequence: _nextSequence++, pcmBytes: segmentBytes, hasSpeech: hasSpeech);
    _segments.add(job);
    _pendingQueue.add(job);
    notifyListeners();
    _pumpQueue();
  }

  void _pumpQueue() {
    while (_pendingQueue.isNotEmpty && _activeJobs.length < maxConcurrentRequests) {
      final job = _pendingQueue.removeFirst();
      late final Future<void> future;
      future = _resolveJob(job, recordingId: _recordingId!, segments: _segments).whenComplete(() {
        _activeJobs.remove(future);
        _pumpQueue();
      });
      _activeJobs.add(future);
    }
  }

  /// Transcribes one segment, retrying with backoff up to
  /// [maxSegmentRetries] times before giving up on it. Never throws -
  /// failure just marks the segment [TranscriptSegment.failed].
  Future<void> _resolveJob(TranscriptSegment job, {
    required String recordingId,
    required List<TranscriptSegment> segments,
    String? language,
  }) async {
    final initialPrompt = segments
        .takeWhile((segment) => segment.sequence < job.sequence && segment.text != null)
        .map((segment) => segment.text!)
        .where((text) => text.isNotEmpty)
        .join(' ');
    while (true) {
      try {
        await _db.saveRecordingSegment(recordingId, job.sequence, job.pcmBytes.length, hasSpeech: job.hasSpeech);
        if (job.hasSpeech == false || (job.hasSpeech == null && job.text == null)) {
          if (job.hasSpeech == false) {
            job.text = '';
            await _db.saveRecordingSegmentText(recordingId, job.sequence, job.pcmBytes.length, '');
          } else {
            job.failed = true;
            _liveTranscriptionReason = LiveTranscriptionReason.failing;
          }
          notifyListeners();
          return;
        }
        job.text ??= await _transcriptionClient.transcribeSegment(
          WavHeader.wrap(job.pcmBytes, format: format),
          language: language ?? this.language,
          recordingId: recordingId,
          segment: job.sequence,
          initialPrompt: initialPrompt,
        );
        await _db.saveRecordingSegmentText(recordingId, job.sequence, job.pcmBytes.length, job.text!);
        if (_liveTranscriptionReason != LiveTranscriptionReason.anonymousLimit) {
          _liveTranscriptionReason = LiveTranscriptionReason.working;
        }
        notifyListeners();
        return;
      } catch (e) {
        job.attempts++;
        final kind = e is TranscriptionException ? e.kind : TranscriptionErrorKind.other;
        _liveTranscriptionReason = _reasonFor(kind);
        if (kind == TranscriptionErrorKind.anonymousLimit ||
            kind == TranscriptionErrorKind.unauthorized ||
            kind == TranscriptionErrorKind.notConfigured ||
            kind == TranscriptionErrorKind.payloadTooLarge ||
            kind == TranscriptionErrorKind.unsupportedMedia ||
            job.attempts > maxSegmentRetries) {
          job.failed = true;
          notifyListeners();
          return;
        }
        notifyListeners();
        await Future<void>.delayed(backoff(job.attempts));
      }
    }
  }

  Future<void> _waitForLiveQueueDrain() async {
    while (_pendingQueue.isNotEmpty || _activeJobs.isNotEmpty) {
      if (_activeJobs.isNotEmpty) {
        await Future.any(_activeJobs);
      } else {
        _pumpQueue();
        if (_activeJobs.isEmpty) break;
      }
    }
  }

  /// Stops recording. Waits for every already-cut segment (including
  /// retries) to settle before returning, so the result's transcript is
  /// final.
  Future<RecorderStopResult> stop({StopReason reason = StopReason.user}) async {
    if (_state != RecorderState.recording && !(_state == RecorderState.failed && _canRetryStop)) {
      throw StateError('RecorderController.stop() called in state $_state');
    }

    _state = RecorderState.finishing;
    _canRetryStop = false;
    notifyListeners();

    try {
      _pageHideUnsubscribe?.call();
      _pageHideUnsubscribe = null;
      _ticker?.cancel();
      _ticker = null;
      await _chunkSubscription?.cancel();
      _chunkSubscription = null;
      await _amplitudeSubscription?.cancel();
      _amplitudeSubscription = null;
      await _audioCapture.stop();
      await _endFeedback();

      // Make sure every chunk already delivered has been appended before we
      // flush the trailing partial segment and finalize the file.
      await _appendChain;
      await _segmenter?.flush();
      await _segmenter?.dispose();
      _segmenter = null;
      await _waitForLiveQueueDrain();

      final finalizeResult =
          await _fileStore.finalizeRecording(_recordingId!, format: format);
      final attachedFile = AttachedFile(
        id: _recordingId!,
        fileName: '$_recordingId.wav',
        filePath: _recordingId!,
        mimeType: 'audio/wav',
        size: finalizeResult.sizeBytes,
        durationMs: finalizeResult.durationMs,
        sha256: finalizeResult.sha256Hex,
        kind: AttachedFile.kindRecording,
        transcriptSlices: _transcriptSlices(_segments),
      );

      await _db.saveLocalRecording(LocalRecordingState(
        id: _recordingId!,
        state: RecordingLifecycleState.complete,
        sizeBytes: finalizeResult.sizeBytes,
        sha256: finalizeResult.sha256Hex,
        durationMs: finalizeResult.durationMs,
      ));

      final result = RecorderStopResult(
        attachedFile: attachedFile,
        transcript: liveTranscript,
        failedSegments: _segments.where((s) => s.failed).toList(),
        stopReason: reason,
      );

      _state = RecorderState.idle;
      _lastStopResult = result;
      notifyListeners();
      return result;
    } catch (e) {
      _failure = AudioCaptureException(AudioCaptureFailureReason.other, '$e');
      _state = RecorderState.failed;
      _canRetryStop = true;
      notifyListeners();
      rethrow;
    }
  }

  /// For a recording that was made offline (or whose live transcription
  /// otherwise never ran): cuts the stored audio into segments and
  /// transcribes them now, with the same bounded concurrency and retry
  /// behaviour as live recording. Does not touch [state]/[segments] - it's
  /// independent of any in-progress recording.
  Future<TranscribeLaterResult> transcribeStoredRecording(
    String recordingId, {
    String? language,
  }) async {
    final bytes = await _fileStore.readBytes(recordingId);
    final declaredLength = WavHeader.readDataLength(bytes);
    final dataLength = declaredLength ?? (bytes.length - wavHeaderLength);
    final pcm = bytes.sublist(
        wavHeaderLength, (wavHeaderLength + dataLength).clamp(wavHeaderLength, bytes.length));

    final segments = await _splitIntoSegments(recordingId, pcm);
    final queue = Queue<TranscriptSegment>.of(segments);
    final active = <Future<void>>{};

    void pump() {
      while (queue.isNotEmpty && active.length < maxConcurrentRequests) {
        final job = queue.removeFirst();
        late final Future<void> future;
        future = _resolveJob(job, recordingId: recordingId, language: language, segments: segments).whenComplete(() => active.remove(future));
        active.add(future);
      }
    }

    pump();
    while (queue.isNotEmpty || active.isNotEmpty) {
      if (active.isNotEmpty) {
        await Future.any(active);
      }
      pump();
    }

    final sorted = [...segments]..sort((a, b) => a.sequence.compareTo(b.sequence));
    final transcript = sorted
        .map((s) => s.text ?? '')
        .where((t) => t.isNotEmpty)
        .join(' ')
        .trim();

    return TranscribeLaterResult(
      transcript: transcript,
      failedSegments: segments.where((s) => s.failed).toList(),
      transcriptSlices: _transcriptSlices(sorted),
    );
  }

  Future<List<TranscriptSegment>> _splitIntoSegments(String recordingId, Uint8List pcm) async {
    final segments = <TranscriptSegment>[];
    final boundaries = await _db.getRecordingSegments(recordingId);
    // Keep submitted identities intact; only unknown speech decisions and an
    // unsegmented recovery tail need local inference before upload.
    final segmenter = SentenceSegmenter(
      format: format,
      maxDuration: segmentDuration,
      onSegment: (bytes, hasSpeech) => segments.add(TranscriptSegment(
        sequence: segments.length,
        pcmBytes: bytes,
        hasSpeech: hasSpeech,
      )),
    );
    try {
      if (boundaries.any((boundary) => boundary.hasSpeech == null && boundary.text == null) ||
          boundaries.fold<int>(0, (sum, boundary) => sum + boundary.length) < pcm.length) {
        // A timed-out initializer still attaches to this disposed segmenter
        // when it eventually completes, which releases the late model.
        await _attachSpeechDetector(segmenter).timeout(const Duration(seconds: 10), onTimeout: () {});
      }
      var offset = 0;
      for (final boundary in boundaries) {
        final bytes = Uint8List.sublistView(pcm, offset, offset + boundary.length);
        if (boundary.hasSpeech == null && boundary.text == null) {
          await segmenter.add(bytes, allowCuts: false);
          await segmenter.flush();
        } else {
          // The model did not observe this slice, so it cannot carry an
          // utterance across it into the next unclassified slice.
          await segmenter.resetSpeechContext();
          segments.add(TranscriptSegment(sequence: segments.length,
              pcmBytes: bytes, hasSpeech: boundary.hasSpeech)..text = boundary.text);
        }
        offset += boundary.length;
      }
      await segmenter.add(Uint8List.sublistView(pcm, offset));
      await segmenter.flush();
    } finally {
      await segmenter.dispose();
    }
    return segments;
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  Future<void> _endFeedback({bool failed = false, bool silent = false}) async {
    if (!_feedbackCapture) return;
    _feedbackCapture = false;
    await feedback?.endRecording(failed: failed, silent: silent);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_audioCapture
        .stop()
        .then((_) => _endFeedback(silent: true))
        .catchError((Object _) {}));
    _pageHideUnsubscribe?.call();
    final segmenter = _segmenter;
    unawaited(_appendChain.then<void>(
      (_) async => segmenter?.dispose(),
      onError: (Object _, StackTrace __) async => segmenter?.dispose(),
    ));
    _ticker?.cancel();
    _chunkSubscription?.cancel();
    _amplitudeSubscription?.cancel();
    super.dispose();
  }
}
