import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/services/audio_capture.dart';

import '../support/fake_audio_capture.dart';

void main() {
  test('start() returns a stream that replays emitted chunks in order',
      () async {
    final capture = FakeAudioCapture();
    final stream = await capture.start();
    expect(capture.isRecording, isTrue);

    final received = <int>[];
    final sub = stream.listen((chunk) => received.add(chunk.first));

    capture.emitChunk(Uint8List.fromList([1]));
    capture.emitChunk(Uint8List.fromList([2]));
    await Future<void>.delayed(Duration.zero);

    expect(received, [1, 2]);

    await capture.stop();
    expect(capture.isRecording, isFalse);
    await sub.cancel();
    await capture.dispose();
  });

  test('start() throws the configured failure and leaves isRecording false',
      () async {
    final capture = FakeAudioCapture()
      ..failureOnStart = AudioCaptureException(
          AudioCaptureFailureReason.permissionDenied, 'denied');

    await expectLater(
      () => capture.start(),
      throwsA(isA<AudioCaptureException>().having(
          (e) => e.reason, 'reason', AudioCaptureFailureReason.permissionDenied)),
    );
    expect(capture.isRecording, isFalse);
    await capture.dispose();
  });

  test('amplitudeStream replays emitted levels', () async {
    final capture = FakeAudioCapture();
    await capture.start();

    final levels = <double>[];
    final sub = capture.amplitudeStream.listen(levels.add);
    capture.emitAmplitude(0.5);
    await Future<void>.delayed(Duration.zero);

    expect(levels, [0.5]);
    await sub.cancel();
    await capture.dispose();
  });
}
