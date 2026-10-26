import 'dart:typed_data';

import 'recording_file_store.dart';
import 'wav.dart';

/// Copies only the selected original PCM, preserving its exact sample boundaries.
Future<Uint8List> readRecordingClip(
    RecordingFileStore store, String id, int startByte, int endByte) async {
  const format = WavFormat.standard;
  if (startByte < 0 ||
      endByte <= startByte ||
      startByte % format.blockAlign != 0 ||
      endByte % format.blockAlign != 0 ||
      endByte - startByte > format.bytesPerSecond * 60 ||
      endByte + wavHeaderLength > await store.size(id)) {
    throw const FormatException('Invalid recording range');
  }
  final pcm = BytesBuilder(copy: false);
  var offset = -wavHeaderLength;
  await for (final chunk in store.openReadStream(id)) {
    final start = (startByte - offset).clamp(0, chunk.length);
    final end = (endByte - offset).clamp(0, chunk.length);
    if (end > start) pcm.add(Uint8List.fromList(chunk.sublist(start, end)));
    offset += chunk.length;
    if (offset >= endByte) break;
  }
  if (pcm.length != endByte - startByte) {
    throw const FormatException('Recording is incomplete');
  }
  return WavHeader.wrap(pcm.takeBytes());
}
