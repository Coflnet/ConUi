import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/models.dart';
import 'audio_capture.dart';
import 'database_service.dart';
import 'page_lifecycle_hooks.dart';
import 'recording_file_store.dart';
import 'segment_cutter.dart';
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

  /// Null until a transcription attempt succeeds.
  String? text;

  /// True once every retry has been exhausted without success.
  bool failed = false;

  int attempts = 0;

  TranscriptSegment({required this.sequence, required this.pcmBytes});
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

  const TranscribeLaterResult({
    required this.transcript,
    required this.failedSegments,
  });
}

/// Drives one recording end to end: microphone capture, durable local
/// storage of every chunk (crash safety), cutting ~[segmentDuration]
/// segments at a quiet point and sending them for live transcription (at
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
  final DatabaseService _db;
  final TranscriptionClient _transcriptionClient;
  final WavFormat format;
  final Duration segmentDuration;
  final Duration maxDuration;
  final int maxSegmentRetries;
  final int maxConcurrentRequests;
  final String? language;
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
    this.maxDuration = const Duration(hours: 2),
    this.maxSegmentRetries = 3,
    this.maxConcurrentRequests = 2,
    this.language,
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

  BytesBuilder _currentSegmentPcm = BytesBuilder();
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
    if (_state == RecorderState.recording ||
        _state == RecorderState.requestingPermission) {
      return;
    }

    _state = RecorderState.requestingPermission;
    _failure = null;
    _lastStopResult = null;
    _anonymousRecording = _transcriptionClient.getToken() == null;
    notifyListeners();
    if (_anonymousRecording && await _transcriptionClient.remainingAnonymousRecordings() == 0) {
      _liveTranscriptionReason = LiveTranscriptionReason.anonymousLimit;
      _state = RecorderState.idle;
      notifyListeners();
      return;
    }

    final Stream<Uint8List> chunkStream;
    try {
      chunkStream = await _audioCapture.start(format: format);
    } on AudioCaptureException catch (e) {
      _failure = e;
      _state = RecorderState.failed;
      notifyListeners();
      return;
    }

    _recordingId = const Uuid().v4();
    _segments.clear();
    _pendingQueue.clear();
    _activeJobs.clear();
    _nextSequence = 0;
    _currentSegmentPcm = BytesBuilder();
    _appendChain = Future.value();
    _recordedPcmBytes = 0;
    _liveTranscriptionReason = !_transcriptionClient.isConfigured
        ? LiveTranscriptionReason.offline
        : LiveTranscriptionReason.notStarted;
    _elapsed = Duration.zero;
    _startedAt = DateTime.now();
    _autoStopping = false;

    await _fileStore.beginRecording(_recordingId!, format: format);
    await _db.saveLocalRecording(LocalRecordingState(
      id: _recordingId!,
      state: RecordingLifecycleState.recording,
    ));

    _state = RecorderState.recording;
    notifyListeners();

    _chunkSubscription = chunkStream.listen(_onChunk);
    _amplitudeSubscription = _audioCapture.amplitudeStream.listen((level) {
      _inputLevel = level;
      notifyListeners();
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) => _onTick());
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
    _currentSegmentPcm.add(chunk);
    _maybeCutSegment();
    if (_anonymousRecording && !_autoStopping && _recordedPcmBytes >= byteLimit) {
      _autoStopping = true;
      unawaited(stop(reason: StopReason.anonymousLimit));
    }
  }

  void _maybeCutSegment() {
    final targetBytes =
        (format.sampleRate * segmentDuration.inMicroseconds / 1000000).round() *
            format.bytesPerSample;
    while (_currentSegmentPcm.length >= targetBytes) {
      _cutAndEnqueueCurrentSegment(targetBytes: targetBytes);
    }
  }

  /// How far back from the end of a segment-sized buffer to search for a
  /// quiet cut point. Scaled to [segmentDuration] (rather than always a
  /// flat 1 second) so a short, configured-for-tests segment duration
  /// still searches within its own buffer instead of degenerately
  /// searching from byte 0 of a buffer shorter than a flat window.
  Duration get _cutSearchWindow {
    final scaled = segmentDuration ~/ 6;
    const oneSecond = Duration(seconds: 1);
    return scaled < oneSecond ? scaled : oneSecond;
  }

  void _cutAndEnqueueCurrentSegment({bool force = false, int? targetBytes}) {
    final bytes = _currentSegmentPcm.toBytes();
    if (bytes.isEmpty) return;

    final cutPoint = force
        ? bytes.length
        : findQuietestCutPoint(Uint8List.sublistView(bytes, 0, targetBytes),
            format: format, searchWindow: _cutSearchWindow);
    final effectiveCut = cutPoint > 0 ? cutPoint : targetBytes ?? bytes.length;

    final segmentBytes = bytes.sublist(0, effectiveCut);
    final remainder = bytes.sublist(effectiveCut);
    _currentSegmentPcm = BytesBuilder()..add(remainder);

    if (segmentBytes.isEmpty) return;

    final job = TranscriptSegment(sequence: _nextSequence++, pcmBytes: segmentBytes);
    _segments.add(job);
    _pendingQueue.add(job);
    notifyListeners();
    _pumpQueue();
  }

  void _pumpQueue() {
    while (_pendingQueue.isNotEmpty && _activeJobs.length < maxConcurrentRequests) {
      final job = _pendingQueue.removeFirst();
      late final Future<void> future;
      future = _resolveJob(job, recordingId: _recordingId!).whenComplete(() {
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
    String? language,
  }) async {
    while (true) {
      try {
        final wav = WavHeader.wrap(job.pcmBytes, format: format);
        final text = await _transcriptionClient.transcribeSegment(
          wav,
          language: language ?? this.language,
          recordingId: recordingId,
          segment: job.sequence,
        );
        job.text = text;
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
    if (_state != RecorderState.recording) {
      throw StateError('RecorderController.stop() called in state $_state');
    }

    _state = RecorderState.finishing;
    notifyListeners();

    _pageHideUnsubscribe?.call();
    _pageHideUnsubscribe = null;
    _ticker?.cancel();
    _ticker = null;
    await _chunkSubscription?.cancel();
    _chunkSubscription = null;
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
    await _audioCapture.stop();

    // Make sure every chunk already delivered has been appended before we
    // flush the trailing partial segment and finalize the file.
    await _appendChain;
    _cutAndEnqueueCurrentSegment(force: true);
    await _waitForLiveQueueDrain();

    final finalizeResult = await _fileStore.finalizeRecording(_recordingId!, format: format);
    final attachedFile = AttachedFile(
      id: _recordingId!,
      fileName: '$_recordingId.wav',
      filePath: _recordingId!,
      mimeType: 'audio/wav',
      size: finalizeResult.sizeBytes,
      durationMs: finalizeResult.durationMs,
      sha256: finalizeResult.sha256Hex,
      kind: AttachedFile.kindRecording,
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

    final segments = _splitIntoSegments(pcm);
    final queue = Queue<TranscriptSegment>.of(segments);
    final active = <Future<void>>{};

    void pump() {
      while (queue.isNotEmpty && active.length < maxConcurrentRequests) {
        final job = queue.removeFirst();
        late final Future<void> future;
        future = _resolveJob(job, recordingId: recordingId, language: language).whenComplete(() => active.remove(future));
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
    );
  }

  List<TranscriptSegment> _splitIntoSegments(Uint8List pcm) {
    final targetBytes =
        (format.sampleRate * segmentDuration.inMicroseconds / 1000000).round() *
            format.bytesPerSample;
    final segments = <TranscriptSegment>[];
    var offset = 0;
    var seq = 0;
    while (offset < pcm.length) {
      final remaining = pcm.length - offset;
      int cutLength;
      if (remaining < targetBytes) {
        cutLength = remaining;
      } else {
        final window = Uint8List.sublistView(pcm, offset, offset + targetBytes);
        final localCut =
            findQuietestCutPoint(window, format: format, searchWindow: _cutSearchWindow);
        cutLength = localCut > 0 ? localCut : targetBytes;
      }
      final segmentBytes = Uint8List.fromList(pcm.sublist(offset, offset + cutLength));
      segments.add(TranscriptSegment(sequence: seq++, pcmBytes: segmentBytes));
      offset += cutLength;
    }
    return segments;
  }

  @override
  void dispose() {
    _pageHideUnsubscribe?.call();
    _ticker?.cancel();
    _chunkSubscription?.cancel();
    _amplitudeSubscription?.cancel();
    super.dispose();
  }
}
