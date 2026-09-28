import 'dart:typed_data';

import 'wav.dart';

/// Finds a good point to cut a PCM buffer into a transcription segment: the
/// quietest point within the last [searchWindow] of [pcm] (raw PCM, no WAV
/// header), so a word is less likely to be split mid-syllable. Falls back
/// to the very end of the buffer when it's shorter than [searchWindow].
///
/// Always returns a byte offset aligned to a whole sample (a multiple of
/// [WavFormat.bytesPerSample]).
int findQuietestCutPoint(
  Uint8List pcm, {
  WavFormat format = WavFormat.standard,
  Duration searchWindow = const Duration(seconds: 1),
  Duration analysisWindow = const Duration(milliseconds: 20),
}) {
  final bytesPerSample = format.bytesPerSample;
  final total = pcm.length;
  if (total < bytesPerSample) return total;

  int bytesFor(Duration d) {
    final samples = (format.sampleRate * d.inMicroseconds / 1000000).round();
    return (samples * bytesPerSample).clamp(bytesPerSample, total);
  }

  final searchWindowBytes = bytesFor(searchWindow);

  // The buffer isn't even as long as the window we'd search - there's
  // nothing meaningful to search for yet, so just take it all rather than
  // risk "finding" a degenerate near-zero cut in a buffer that's really
  // just one contiguous stretch.
  if (total <= searchWindowBytes) return total;

  final analysisBytes = bytesFor(analysisWindow);

  var windowStart = total - searchWindowBytes;
  windowStart -= windowStart % bytesPerSample;

  var bestOffset = total; // default: cut at the very end of the buffer
  var bestEnergy = double.infinity;

  var offset = windowStart;
  while (offset + analysisBytes <= total) {
    final energy = _averageAbsAmplitude(pcm, offset, analysisBytes);
    if (energy < bestEnergy) {
      bestEnergy = energy;
      bestOffset = offset;
    }
    offset += analysisBytes;
  }

  return bestOffset - (bestOffset % bytesPerSample);
}

double _averageAbsAmplitude(Uint8List pcm, int offset, int length) {
  final byteData = ByteData.sublistView(pcm, offset, offset + length);
  var sum = 0;
  var count = 0;
  for (var i = 0; i + 1 < length; i += 2) {
    sum += byteData.getInt16(i, Endian.little).abs();
    count++;
  }
  return count == 0 ? 0 : sum / count;
}
