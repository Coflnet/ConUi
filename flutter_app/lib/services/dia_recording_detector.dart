import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../models/event.dart';
import 'recording_file_store.dart';
import 'transcription_client.dart';
import 'wav.dart';

/// Recognizes bounded original audio chunks; offsets never derive from text length.
Future<List<RecordingTranscriptSlice>> detectRecordingTranscript({
  required AttachedFile file,
  required RecordingFileStore store,
  required TranscriptionClient client,
  String? language,
  bool Function()? isCancelled,
}) async {
  void checkCancelled() {
    if (isCancelled?.call() ?? false) {
      throw StateError('Recording analysis cancelled');
    }
  }

  checkCancelled();
  final size = await store.size(file.id);
  final dataLength = size - wavHeaderLength;
  if (dataLength <= 0 || dataLength % WavFormat.standard.blockAlign != 0) {
    throw const FormatException('Invalid recording WAV');
  }
  final header = Uint8List(wavHeaderLength);
  var read = 0;
  // Validate the entire stream before spending any recording allowance.
  await for (final chunk in store.openReadStream(file.id)) {
    checkCancelled();
    if (read < wavHeaderLength) {
      header.setRange(
          read, (read + chunk.length).clamp(0, wavHeaderLength), chunk);
    }
    read += chunk.length;
    if (read > size) {
      throw const FormatException('Invalid recording WAV length');
    }
  }
  if (read != size) throw const FormatException('Recording is incomplete');
  final expected = WavHeader.build(dataLength: dataLength);
  for (var i = 0; i < header.length; i++) {
    if (header[i] != expected[i]) {
      throw const FormatException('Invalid recording WAV');
    }
  }
  if (client.getToken() == null &&
      dataLength > 60 * WavFormat.standard.bytesPerSecond) {
    throw const TranscriptionException(TranscriptionErrorKind.anonymousLimit,
        'Sign in to recognize recordings longer than one minute.',
        slug: 'anonymous_recording_too_long');
  }

  final analysisId = const Uuid().v4();
  final slices = <RecordingTranscriptSlice>[];
  final pcm = Uint8List(6 * WavFormat.standard.bytesPerSecond);
  var filled = 0, offset = 0, segment = 0;
  Future<void> transcribe() async {
    checkCancelled();
    final text = (await client.transcribeSegment(
      WavHeader.wrap(Uint8List.sublistView(pcm, 0, filled)),
      language: language,
      recordingId: analysisId,
      segment: segment++,
    ))
        .trim();
    checkCancelled();
    if (text.isNotEmpty) {
      slices.add(RecordingTranscriptSlice(
          startByte: offset, endByte: offset + filled, text: text));
    }
    offset += filled;
    filled = 0;
  }

  var position = -wavHeaderLength;
  await for (final chunk in store.openReadStream(file.id)) {
    checkCancelled();
    var start = (-position).clamp(0, chunk.length);
    position += chunk.length;
    if (position > dataLength) {
      throw const FormatException('Invalid recording WAV length');
    }
    while (start < chunk.length) {
      final count = (chunk.length - start).clamp(0, pcm.length - filled);
      pcm.setRange(filled, filled + count, chunk, start);
      filled += count;
      start += count;
      if (filled == pcm.length) await transcribe();
    }
  }
  if (position != dataLength) {
    throw const FormatException('Recording is incomplete');
  }
  if (filled > 0) await transcribe();
  checkCancelled();
  return slices;
}
