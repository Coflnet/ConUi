import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Audio format used for every recording and every transcription segment in
/// this app: mono, 16-bit PCM, 16 kHz. Fixed (not configurable per
/// recording) because that is exactly what the transcription backend
/// expects, it can be appended to incrementally while recording, and a
/// plain PCM WAV plays back on every platform without a codec.
class WavFormat {
  final int sampleRate;
  final int numChannels;
  final int bitsPerSample;

  const WavFormat({
    this.sampleRate = 16000,
    this.numChannels = 1,
    this.bitsPerSample = 16,
  });

  int get bytesPerSample => bitsPerSample ~/ 8;
  int get blockAlign => numChannels * bytesPerSample;
  int get bytesPerSecond => sampleRate * blockAlign;

  /// The one format this app ever records or transcribes: mono/16-bit/16kHz.
  static const standard = WavFormat();
}

/// Every canonical PCM WAV file starts with exactly this many header bytes.
const int wavHeaderLength = 44;

/// Builds and parses the 44-byte canonical PCM WAV header.
class WavHeader {
  static Uint8List build({
    required int dataLength,
    WavFormat format = WavFormat.standard,
  }) {
    final bytes = ByteData(wavHeaderLength);
    void writeAscii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        bytes.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    writeAscii(0, 'RIFF');
    bytes.setUint32(4, 36 + dataLength, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    bytes.setUint32(16, 16, Endian.little); // fmt chunk size (PCM)
    bytes.setUint16(20, 1, Endian.little); // audio format = PCM
    bytes.setUint16(22, format.numChannels, Endian.little);
    bytes.setUint32(24, format.sampleRate, Endian.little);
    bytes.setUint32(28, format.bytesPerSecond, Endian.little);
    bytes.setUint16(32, format.blockAlign, Endian.little);
    bytes.setUint16(34, format.bitsPerSample, Endian.little);
    writeAscii(36, 'data');
    bytes.setUint32(40, dataLength, Endian.little);
    return bytes.buffer.asUint8List();
  }

  /// Wraps raw PCM [data] in a WAV header, ready to send as one file.
  static Uint8List wrap(Uint8List data, {WavFormat format = WavFormat.standard}) {
    final builder = BytesBuilder(copy: false);
    builder.add(build(dataLength: data.length, format: format));
    builder.add(data);
    return builder.toBytes();
  }

  /// Reads the declared PCM data length (the 'data' subchunk size) from a
  /// canonical WAV header, or null if [bytes] doesn't look like one.
  static int? readDataLength(Uint8List bytes) {
    if (bytes.length < wavHeaderLength) return null;
    if (String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF') return null;
    if (String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') return null;
    return ByteData.sublistView(bytes).getUint32(40, Endian.little);
  }
}

/// Result of finalizing (or repairing) a recording: everything an
/// [AttachedFile] needs to know about the bytes now sitting in a
/// RecordingFileStore.
class RecordingFinalizeResult {
  final int sizeBytes;
  final String sha256Hex;
  final int durationMs;

  const RecordingFinalizeResult({
    required this.sizeBytes,
    required this.sha256Hex,
    required this.durationMs,
  });
}

/// Computes size, SHA-256 and duration for a complete WAV file (header
/// included) given as a byte stream, without holding the whole file in
/// memory at once. Used by both the native and web RecordingFileStore so
/// the integrity calculation is identical everywhere.
Future<RecordingFinalizeResult> hashWavStream(
  Stream<List<int>> fullFileBytes, {
  required int dataLength,
  WavFormat format = WavFormat.standard,
}) async {
  final output = _DigestAccumulator();
  final input = sha256.startChunkedConversion(output);
  var total = 0;
  await for (final chunk in fullFileBytes) {
    input.add(chunk);
    total += chunk.length;
  }
  input.close();
  final digest = output.digest!;
  final durationMs = format.bytesPerSecond == 0
      ? 0
      : (dataLength * 1000 / format.bytesPerSecond).round();
  return RecordingFinalizeResult(
    sizeBytes: total,
    sha256Hex: digest.toString(),
    durationMs: durationMs,
  );
}

/// Minimal [Sink] that just remembers the one [Digest] a hash's chunked
/// conversion produces when [close]d.
class _DigestAccumulator implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}
