// Import the PCM iterator directly; the public facade
// also imports a microphone handler tied to a different record major version.
// ignore_for_file: implementation_imports

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:vad/src/core/vad_event.dart';
import 'package:vad/src/core/vad_iterator.dart';

import 'segment_cutter.dart';
import 'wav.dart';

/// DiaFlutter's Silero iterator consumes the existing microphone's PCM;
/// its padded/trimmed speech audio is deliberately not used for storage.
abstract class SpeechDetector {
  Future<bool> speechEnded(Uint8List frame);
  bool get hasSpeech;
  void reset({bool continuing = false});
  Future<void> dispose();
}

class DiaSpeechDetector implements SpeechDetector {
  final VadIterator _iterator;
  bool _ended = false;
  bool _hasSpeech = false;
  bool _continuingSpeech = false;

  DiaSpeechDetector._(this._iterator) {
    _iterator.setVadEventCallback((event) {
      if (event.type == VadEventType.start) _ended = false;
      if (event.type == VadEventType.end) _ended = true;
      if (event.type == VadEventType.realStart) _hasSpeech = true;
      // A duration cut must not require another three positive frames for
      // a short continuation. It still needs speech in this segment itself.
      if (event.type == VadEventType.frameProcessed &&
          _continuingSpeech &&
          (event.probabilities?.isSpeech ?? 0) >= 0.3) {
        _hasSpeech = true;
      }
      if (event.type == VadEventType.error) {
        throw StateError('Voice activity inference failed');
      }
    });
  }

  static Future<SpeechDetector> create() async => DiaSpeechDetector._(
        await VadIterator.create(
          isDebug: false,
          sampleRate: 16000,
          frameSamples: 512,
          positiveSpeechThreshold: 0.3,
          negativeSpeechThreshold: 0.2,
          redemptionFrames: 16, // 512ms of silence ends an utterance.
          preSpeechPadFrames: 1,
          minSpeechFrames: 3,
          model: 'v5',
          baseAssetPath: kIsWeb
              ? Uri.base.resolve('assets/assets/vad/').toString()
              : 'assets/vad/',
          onnxWASMBasePath: Uri.base.resolve('vad/').toString(),
        ),
      );

  @override
  Future<bool> speechEnded(Uint8List frame) async {
    await _iterator.processAudioData(frame);
    return _ended;
  }

  @override
  bool get hasSpeech => _hasSpeech;

  @override
  void reset({bool continuing = false}) {
    _continuingSpeech = continuing && _hasSpeech && !_ended;
    _hasSpeech = false;
    _ended = false;
    _iterator.reset();
  }

  @override
  Future<void> dispose() => _iterator.release();
}

/// Emits every original PCM byte with true for qualified speech, false for
/// fully analyzed nonspeech, or null when model coverage is unavailable.
class SentenceSegmenter {
  static const _frameBytes = 512 * 2;
  final WavFormat format;
  final Duration maxDuration;
  final void Function(Uint8List, bool?) onSegment;
  SpeechDetector? _detector;
  bool _disposed = false;
  final BytesBuilder _buffer = BytesBuilder();
  int _processed = 0;
  int? _speechOffset;

  SentenceSegmenter({
    required this.format,
    required this.maxDuration,
    required this.onSegment,
  });

  Future<void> attachDetector(SpeechDetector? detector) async {
    if (_disposed) {
      await detector?.dispose();
    } else if (format.sampleRate == 16000 &&
        format.numChannels == 1 &&
        format.bitsPerSample == 16) {
      _detector = detector;
    } else {
      await detector?.dispose();
    }
  }

  Future<bool> _analyzeFrame(Uint8List bytes, int end) async {
    final detector = _detector;
    if (detector == null) return false;
    final frame = Uint8List(_frameBytes)
      ..setRange(0, end - _processed, bytes, _processed);
    try {
      final ended = await detector.speechEnded(frame);
      _processed = end;
      if (detector.hasSpeech) _speechOffset ??= end;
      return ended;
    } catch (_) {
      await _disableDetector();
      return false;
    }
  }

  Future<void> _emit(Uint8List bytes, int cut) async {
    // Finish the boundary's coverage, padding only the inference frame.
    // Quiet cuts can precede analyzed lookahead, so speech after the cut
    // must not qualify the silence before it.
    while (_detector != null && _processed < cut) {
      await _analyzeFrame(bytes, (_processed + _frameBytes).clamp(0, cut));
    }
    final hasSpeech = _speechOffset != null && _speechOffset! <= cut
        ? true
        : _processed >= cut
            ? false
            : null;
    onSegment(Uint8List.sublistView(bytes, 0, cut), hasSpeech);
    await resetSpeechContext(continuing: true);
  }

  /// Clear classification across skipped audio without reloading the model.
  Future<void> resetSpeechContext({bool continuing = false}) async {
    _processed = 0;
    _speechOffset = null;
    try {
      _detector?.reset(continuing: continuing);
    } catch (_) {
      await _disableDetector();
    }
  }

  /// Disable cuts when replaying an authoritative saved slice; flush then
  /// classifies exactly that slice without changing its bytes or identity.
  Future<void> add(Uint8List chunk, {bool allowCuts = true}) async {
    _buffer.add(chunk);
    var bytes = _buffer.takeBytes();
    final target =
        (format.sampleRate * maxDuration.inMicroseconds / 1000000).round() *
            format.bytesPerSample;
    final minimum =
        format.bytesPerSecond; // <=61 guest segments including tail.
    while (true) {
      int? cut;
      if (_detector != null &&
          _processed + _frameBytes <= bytes.length &&
          (!allowCuts || _processed + _frameBytes <= target)) {
        final ended = await _analyzeFrame(bytes, _processed + _frameBytes);
        if (allowCuts && ended && _processed >= minimum) cut = _processed;
        if (cut == null && _detector != null) continue;
      }
      if (cut == null && allowCuts && bytes.length >= target) {
        final scaled = maxDuration ~/ 6;
        cut = findQuietestCutPoint(Uint8List.sublistView(bytes, 0, target),
            format: format,
            searchWindow: scaled < const Duration(seconds: 1)
                ? scaled
                : const Duration(seconds: 1));
        if (cut <= 0) cut = target;
      }
      if (cut == null) break;
      await _emit(bytes, cut);
      bytes = Uint8List.sublistView(bytes, cut);
    }
    _buffer.add(bytes);
  }

  Future<void> flush() async {
    final bytes = _buffer.takeBytes();
    if (bytes.isNotEmpty) await _emit(bytes, bytes.length);
  }

  Future<void> _disableDetector() async {
    final detector = _detector;
    _detector = null;
    try {
      await detector?.dispose();
    } catch (_) {}
  }

  Future<void> dispose() async {
    _disposed = true;
    await _disableDetector();
  }
}
