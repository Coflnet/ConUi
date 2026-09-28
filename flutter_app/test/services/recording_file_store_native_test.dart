// Tests for NativeRecordingFileStore against a real temporary directory,
// including the crash-and-recover case described in RecordingFileStore's
// doc comment: a recording that was never finalized (e.g. the app was
// killed mid-recording) must still have every byte captured so far, and
// finalizeRecording() must be able to repair its WAV header from exactly
// those bytes.
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/services/recording_file_store_native.dart';
import 'package:relationship_manager/services/wav.dart';

Uint8List _pcmChunk(int seed, int length) {
  return Uint8List.fromList(
      List<int>.generate(length, (i) => (seed + i) % 256));
}

void main() {
  late Directory tempDir;
  late NativeRecordingFileStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('recording_store_test');
    store = NativeRecordingFileStore(baseDirectory: tempDir);
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('records chunks, finalizes, and produces a valid WAV file', () async {
    const id = 'rec-1';
    final chunk1 = _pcmChunk(0, 1000);
    final chunk2 = _pcmChunk(1000, 500);

    await store.beginRecording(id);
    await store.appendChunk(id, chunk1);
    await store.appendChunk(id, chunk2);
    final result = await store.finalizeRecording(id);

    final bytes = await store.readBytes(id);
    expect(bytes.length, wavHeaderLength + chunk1.length + chunk2.length);
    expect(WavHeader.readDataLength(bytes), chunk1.length + chunk2.length);
    expect(bytes.sublist(wavHeaderLength, wavHeaderLength + chunk1.length),
        chunk1);
    expect(bytes.sublist(wavHeaderLength + chunk1.length), chunk2);

    expect(result.sizeBytes, bytes.length);
    expect(result.sha256Hex, crypto.sha256.convert(bytes).toString());

    final expectedDurationMs =
        ((chunk1.length + chunk2.length) * 1000 / WavFormat.standard.bytesPerSecond)
            .round();
    expect(result.durationMs, expectedDurationMs);

    expect(await store.size(id), bytes.length);
    expect(await store.exists(id), isTrue);
  });

  test('finalizeRecording is idempotent', () async {
    const id = 'rec-idempotent';
    await store.beginRecording(id);
    await store.appendChunk(id, _pcmChunk(0, 200));
    final first = await store.finalizeRecording(id);
    final second = await store.finalizeRecording(id);

    expect(second.sha256Hex, first.sha256Hex);
    expect(second.sizeBytes, first.sizeBytes);
    expect(second.durationMs, first.durationMs);
  });

  test('delete removes the file and exists() returns false', () async {
    const id = 'rec-delete';
    await store.beginRecording(id);
    await store.appendChunk(id, _pcmChunk(0, 100));
    await store.finalizeRecording(id);
    expect(await store.exists(id), isTrue);

    await store.delete(id);

    expect(await store.exists(id), isFalse);
    expect(() => store.readBytes(id), throwsStateError);
  });

  test('listIds reports every recording, finished or not', () async {
    await store.beginRecording('finished');
    await store.appendChunk('finished', _pcmChunk(0, 10));
    await store.finalizeRecording('finished');

    await store.beginRecording('unfinished');
    await store.appendChunk('unfinished', _pcmChunk(0, 10));
    // Deliberately not finalized.

    final ids = await store.listIds();
    expect(ids, containsAll(['finished', 'unfinished']));
  });

  group('crash recovery', () {
    test(
        'a recording abandoned without finalize keeps its bytes and can be repaired',
        () async {
      const id = 'rec-crash';
      final chunk1 = _pcmChunk(7, 3000);
      final chunk2 = _pcmChunk(42, 2500);

      await store.beginRecording(id);
      await store.appendChunk(id, chunk1);
      await store.appendChunk(id, chunk2);
      // No finalizeRecording() call: simulates the app being killed here.
      // Deliberately not closing the writer either - a real crash wouldn't.

      // The temp file must already contain everything written so far,
      // flushed to disk as it was appended (crash safety), even though it
      // was never finalized.
      final tempFile = File('${tempDir.path}/recordings/$id.wav.tmp');
      expect(tempFile.existsSync(), isTrue);
      final onDiskLength = tempFile.lengthSync();
      expect(onDiskLength, wavHeaderLength + chunk1.length + chunk2.length);
      // The header written by beginRecording still claims zero data bytes -
      // that's exactly what makes this recording "incomplete".
      final rawBytes = tempFile.readAsBytesSync();
      expect(WavHeader.readDataLength(rawBytes), 0);

      // Recovery: a fresh store instance (as a restarted app would create)
      // pointed at the same directory finds and repairs it.
      final recoveredStore = NativeRecordingFileStore(baseDirectory: tempDir);
      expect(await recoveredStore.exists(id), isTrue);
      final result = await recoveredStore.finalizeRecording(id);

      expect(result.sizeBytes, onDiskLength);
      final repairedBytes = await recoveredStore.readBytes(id);
      expect(WavHeader.readDataLength(repairedBytes),
          chunk1.length + chunk2.length);
      expect(
        repairedBytes.sublist(wavHeaderLength, wavHeaderLength + chunk1.length),
        chunk1,
      );
      expect(
        repairedBytes.sublist(wavHeaderLength + chunk1.length),
        chunk2,
      );
      expect(result.sha256Hex, crypto.sha256.convert(repairedBytes).toString());

      // The recording is no longer a dangling .tmp file.
      expect(
          File('${tempDir.path}/recordings/$id.wav.tmp').existsSync(), isFalse);
      expect(File('${tempDir.path}/recordings/$id.wav').existsSync(), isTrue);
    });
  });
}
