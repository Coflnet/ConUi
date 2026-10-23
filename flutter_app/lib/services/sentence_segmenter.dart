// Dia exposes its PCM iterator through internal libraries; the public facade
// also imports a microphone handler tied to a different record major version.
// ignore_for_file: implementation_imports

import 'dart:typed_data';

import 'package:vad/src/core/vad_event.dart';
import 'package:vad/src/core/vad_iterator.dart';

import 'segment_cutter.dart';
import 'wav.dart';

/// DiaFlutter's Silero iterator consumes the existing microphone's PCM;
/// its padded/trimmed speech audio is deliberately not used for storage.
abstract class SpeechDetector {
  Future<bool> speechEnded(Uint8List frame);
  void reset();
  Future<void> dispose();
}

class DiaSpeechDetector implements SpeechDetector {
  final VadIterator _iterator;
  bool _ended = false;

  DiaSpeechDetector._(this._iterator) {
    _iterator.setVadEventCallback((event) {
      if (event.type == VadEventType.start) _ended = false;
      if (event.type == VadEventType.end) _ended = true;
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
          onnxWASMBasePath: Uri.base.resolve('vad/').toString(),
        ),
      );

  @override
  Future<bool> speechEnded(Uint8List frame) async {
    await _iterator.processAudioData(frame);
    return _ended;
  }

  @override
  void reset() {
    _ended = false;
    _iterator.reset();
  }

  @override
  Future<void> dispose() => _iterator.release();
}

/// Frame-aligned speech-end detection independent of microphone chunk sizes.
/// Every original PCM byte is emitted exactly once.
class SentenceSegmenter {
  final WavFormat format;
  final Duration maxDuration;
  final void Function(Uint8List) onSegment;
  SpeechDetector? _detector;
  bool _disposed = false;
  final BytesBuilder _buffer = BytesBuilder();
  int _processed = 0;

  SentenceSegmenter({
    required this.format,
    required this.maxDuration,
    required this.onSegment,
  });

  Future<void> attachDetector(SpeechDetector? detector) async {
    if (_disposed) {
      await detector?.dispose();
    } else {
      _detector = detector;
    }
  }

  Future<void> add(Uint8List chunk) async {
    _buffer.add(chunk);
    var bytes = _buffer.takeBytes();
    final target =
        (format.sampleRate * maxDuration.inMicroseconds / 1000000).round() *
            format.bytesPerSample;
    final minimum =
        format.bytesPerSecond; // <=61 guest segments including tail.
    const frameBytes = 512 * 2;
    while (true) {
      int? cut;
      if (_detector != null &&
          format.sampleRate == 16000 &&
          format.numChannels == 1 &&
          format.bitsPerSample == 16 &&
          _processed + frameBytes <= bytes.length &&
          _processed + frameBytes <= target) {
        try {
          final ended = await _detector!.speechEnded(Uint8List.sublistView(
              bytes, _processed, _processed + frameBytes));
          _processed += frameBytes;
          if (ended && _processed >= minimum) cut = _processed;
        } catch (_) {
          try {
            await _detector!.dispose();
          } catch (_) {}
          _detector = null; // Inference failure must never interrupt recording.
        }
        if (cut == null && _detector != null) continue;
      }
      if (cut == null && bytes.length >= target) {
        final scaled = maxDuration ~/ 6;
        cut = findQuietestCutPoint(Uint8List.sublistView(bytes, 0, target),
            format: format,
            searchWindow: scaled < const Duration(seconds: 1)
                ? scaled
                : const Duration(seconds: 1));
        if (cut <= 0) cut = target;
      }
      if (cut == null) break;
      onSegment(Uint8List.sublistView(bytes, 0, cut));
      bytes = Uint8List.sublistView(bytes, cut);
      _processed = 0;
      _detector?.reset();
    }
    _buffer.add(bytes);
  }

  void flush() {
    final bytes = _buffer.takeBytes();
    if (bytes.isNotEmpty) onSegment(bytes);
    _processed = 0;
  }

  Future<void> dispose() async {
    _disposed = true;
    try {
      await _detector?.dispose();
    } catch (_) {}
    _detector = null;
  }
}
