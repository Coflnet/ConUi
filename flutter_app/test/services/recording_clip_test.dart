import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/services/recording_clip.dart';
import 'package:relationship_manager/services/recording_file_store.dart';
import 'package:relationship_manager/services/wav.dart';

class _StreamStore implements RecordingFileStore {
  final Uint8List wav;
  final int chunkSize;
  final int? declaredSize;
  int reads = 0;
  _StreamStore(this.wav, {this.chunkSize = 7, this.declaredSize});

  @override
  Future<int> size(String id) async => declaredSize ?? wav.length;

  @override
  Stream<List<int>> openReadStream(String id) async* {
    for (var offset = 0; offset < wav.length; offset += chunkSize) {
      reads++;
      yield Uint8List.sublistView(wav, offset, (offset + chunkSize).clamp(0, wav.length));
    }
  }

  @override
  Future<Uint8List> readBytes(String id) => throw StateError('Whole-file read forbidden');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('extracts exact samples across header and arbitrary stream boundaries', () async {
    final pcm = Uint8List.fromList(List.generate(1000, (index) => index % 256));
    for (final chunkSize in [1, 7, 43, 44, 45, 137, 2000]) {
      final store = _StreamStore(WavHeader.wrap(pcm), chunkSize: chunkSize);
      for (final range in [(0, 2), (6, 42), (138, 740), (996, 1000)]) {
        final clip = await readRecordingClip(store, 'recording', range.$1, range.$2);
        expect(clip, WavHeader.wrap(Uint8List.sublistView(pcm, range.$1, range.$2)));
      }
    }
  });

  test('stops streaming once the selected range is complete', () async {
    final store = _StreamStore(WavHeader.wrap(Uint8List(10000)), chunkSize: 100);
    await readRecordingClip(store, 'recording', 0, 200);
    expect(store.reads, 3);
  });

  test('rejects empty, reversed, negative, odd, oversized and out-of-bounds ranges', () async {
    final store = _StreamStore(WavHeader.wrap(Uint8List(1000)), declaredSize: 2000000);
    for (final range in [(-2, 2), (0, 0), (4, 2), (1, 4), (0, 3), (0, 1920002), (1999998, 2000000)]) {
      await expectLater(readRecordingClip(store, 'recording', range.$1, range.$2), throwsFormatException);
    }
    expect(store.reads, 0);
  });

  test('accepts exactly sixty seconds and rejects a truncated stream', () async {
    final pcm = Uint8List(60 * WavFormat.standard.bytesPerSecond);
    final store = _StreamStore(WavHeader.wrap(pcm), chunkSize: 65537);
    final clip = await readRecordingClip(store, 'recording', 0, pcm.length);
    expect(WavHeader.readDataLength(clip), pcm.length);
    final truncated = _StreamStore(WavHeader.wrap(Uint8List(100)), declaredSize: 244);
    await expectLater(readRecordingClip(truncated, 'recording', 0, 200), throwsFormatException);
  });
}
