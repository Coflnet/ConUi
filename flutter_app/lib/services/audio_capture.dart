import 'dart:typed_data';

import 'wav.dart';

/// Why starting the microphone failed, so callers can show a specific
/// message instead of a generic error.
enum AudioCaptureFailureReason {
  /// The user (or the OS) denied the microphone permission.
  permissionDenied,

  /// No microphone/input device is available on this machine.
  noMicrophone,

  /// Anything else (platform error, unsupported browser, ...).
  other,
}

class AudioCaptureException implements Exception {
  final AudioCaptureFailureReason reason;
  final String message;

  AudioCaptureException(this.reason, this.message);

  @override
  String toString() => 'AudioCaptureException($reason): $message';
}

/// Thin wrapper around whatever platform microphone plugin the app uses
/// (the `record` package, see RecordPackageAudioCapture), so the rest of
/// the app - and tests, via a fake - never depend on that package's API
/// directly.
abstract class AudioCapture {
  /// True once [start] has succeeded and before [stop] completes.
  bool get isRecording;

  /// Starts capturing microphone audio and returns a stream of raw PCM
  /// chunks (no WAV header) in [format]. Throws [AudioCaptureException] if
  /// the microphone can't be opened - most importantly with
  /// [AudioCaptureFailureReason.permissionDenied] or
  /// [AudioCaptureFailureReason.noMicrophone] so the UI can show a clear,
  /// specific message.
  Future<Stream<Uint8List>> start({WavFormat format = WavFormat.standard});

  /// Stops capturing. Safe to call when not currently recording.
  Future<void> stop();

  /// Roughly-normalized input level in `[0.0, 1.0]`, sampled periodically
  /// while recording (0 = silence, 1 = loud). Implementations may emit at a
  /// coarser rate than audio chunks arrive.
  Stream<double> get amplitudeStream;
}
