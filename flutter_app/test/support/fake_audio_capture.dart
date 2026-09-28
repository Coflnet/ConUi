import 'dart:async';
import 'dart:typed_data';

import 'package:relationship_manager/services/audio_capture.dart';
import 'package:relationship_manager/services/wav.dart';

/// Test double for [AudioCapture]: no microphone, no platform channel.
/// Tests drive it by calling [emitChunk]/[emitAmplitude] after [start], and
/// can make [start] throw by setting [failureOnStart] beforehand.
class FakeAudioCapture implements AudioCapture {
  AudioCaptureException? failureOnStart;

  StreamController<Uint8List>? _chunkController;
  final StreamController<double> _amplitudeController =
      StreamController<double>.broadcast();

  bool _isRecording = false;

  @override
  bool get isRecording => _isRecording;

  @override
  Stream<double> get amplitudeStream => _amplitudeController.stream;

  @override
  Future<Stream<Uint8List>> start({WavFormat format = WavFormat.standard}) async {
    final failure = failureOnStart;
    if (failure != null) {
      throw failure;
    }
    _isRecording = true;
    _chunkController = StreamController<Uint8List>.broadcast();
    return _chunkController!.stream;
  }

  @override
  Future<void> stop() async {
    _isRecording = false;
    await _chunkController?.close();
    _chunkController = null;
  }

  /// Test helper: simulate the microphone producing a chunk of PCM audio.
  void emitChunk(Uint8List chunk) {
    _chunkController?.add(chunk);
  }

  /// Test helper: simulate an amplitude reading.
  void emitAmplitude(double level) {
    _amplitudeController.add(level);
  }

  Future<void> dispose() async {
    await _chunkController?.close();
    await _amplitudeController.close();
  }
}
