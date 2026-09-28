import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import 'audio_capture.dart';
import 'wav.dart';

/// [AudioCapture] backed by the `record` plugin. Captures raw PCM16 audio
/// as a stream on Android and web, which is exactly what `record` supports
/// for `AudioEncoder.pcm16bits` streaming.
class RecordPackageAudioCapture implements AudioCapture {
  final AudioRecorder _recorder;

  RecordPackageAudioCapture({AudioRecorder? recorder})
      : _recorder = recorder ?? AudioRecorder();

  bool _isRecording = false;
  StreamController<double>? _amplitudeController;
  StreamSubscription<Amplitude>? _amplitudeSubscription;

  @override
  bool get isRecording => _isRecording;

  @override
  Stream<double> get amplitudeStream =>
      _amplitudeController?.stream ?? const Stream<double>.empty();

  @override
  Future<Stream<Uint8List>> start({WavFormat format = WavFormat.standard}) async {
    final bool hasPermission;
    try {
      hasPermission = await _recorder.hasPermission();
    } catch (e) {
      throw AudioCaptureException(
          AudioCaptureFailureReason.other, 'Could not check microphone permission: $e');
    }
    if (!hasPermission) {
      throw AudioCaptureException(AudioCaptureFailureReason.permissionDenied,
          'Microphone permission was denied.');
    }

    final Stream<Uint8List> stream;
    try {
      stream = await _recorder.startStream(RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: format.sampleRate,
        numChannels: format.numChannels,
      ));
    } catch (e) {
      throw AudioCaptureException(
          _classifyStartFailure(e), 'Could not start recording: $e');
    }

    _isRecording = true;
    final amplitudeController = StreamController<double>.broadcast();
    _amplitudeController = amplitudeController;
    _amplitudeSubscription = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 200))
        .listen((amplitude) {
      // dBFS: roughly -60 (quiet) to 0 (loudest); normalize to [0, 1].
      final normalized = ((amplitude.current + 60) / 60).clamp(0.0, 1.0);
      amplitudeController.add(normalized);
    });

    return stream;
  }

  AudioCaptureFailureReason _classifyStartFailure(Object error) {
    final message = error.toString().toLowerCase();
    if (message.contains('permission')) {
      return AudioCaptureFailureReason.permissionDenied;
    }
    if (message.contains('microphone') ||
        message.contains('device') ||
        message.contains('input')) {
      return AudioCaptureFailureReason.noMicrophone;
    }
    return AudioCaptureFailureReason.other;
  }

  @override
  Future<void> stop() async {
    if (!_isRecording) return;
    _isRecording = false;
    await _recorder.stop();
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
    await _amplitudeController?.close();
    _amplitudeController = null;
  }
}
