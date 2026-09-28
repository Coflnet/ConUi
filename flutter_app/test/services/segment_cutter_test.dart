import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/services/segment_cutter.dart';
import 'package:relationship_manager/services/wav.dart';

Uint8List _pcmOfAmplitudes(List<int> amplitudes) {
  final bytes = ByteData(amplitudes.length * 2);
  for (var i = 0; i < amplitudes.length; i++) {
    bytes.setInt16(i * 2, amplitudes[i], Endian.little);
  }
  return bytes.buffer.asUint8List();
}

void main() {
  test('cuts at the quietest point within the trailing search window', () {
    // 2 seconds of loud audio, then 200ms of silence, then 800ms more of
    // loud audio - all at 16kHz. The 1-second trailing search window
    // therefore contains: the tail of the first loud stretch, the silent
    // gap, and the second loud stretch. The quietest point must land
    // inside (or right at the edge of) the silent gap.
    const sampleRate = 16000;
    final loud1 = List.filled(sampleRate * 2, 20000);
    final silence = List.filled((sampleRate * 0.2).round(), 0);
    final loud2 = List.filled((sampleRate * 0.8).round(), 20000);
    final pcm = _pcmOfAmplitudes([...loud1, ...silence, ...loud2]);

    final silenceStartByte = loud1.length * 2;
    final silenceEndByte = silenceStartByte + silence.length * 2;

    final cut = findQuietestCutPoint(pcm);

    expect(cut, greaterThanOrEqualTo(silenceStartByte));
    expect(cut, lessThanOrEqualTo(silenceEndByte));
    expect(cut % WavFormat.standard.bytesPerSample, 0);
  });

  test('falls back to the end of the buffer when shorter than the search window', () {
    final pcm = _pcmOfAmplitudes(List.filled(100, 5000));
    final cut = findQuietestCutPoint(pcm, searchWindow: const Duration(seconds: 1));
    expect(cut, pcm.length);
  });

  test('returns 0 for an empty buffer', () {
    final cut = findQuietestCutPoint(Uint8List(0));
    expect(cut, 0);
  });
}
