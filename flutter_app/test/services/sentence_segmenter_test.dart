import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/services/sentence_segmenter.dart';
import 'package:relationship_manager/services/wav.dart';

import '../support/fake_speech_detector.dart';

void main() {
  test(
      'speech ends cut before six seconds with identical bytes across chunk sizes',
      () async {
    final pcm = Uint8List.fromList(List.generate(3 * 32000, (i) => i % 256));
    Future<List<Uint8List>> split(int chunkSize) async {
      final segments = <Uint8List>[];
      final cutter = SentenceSegmenter(
          format: WavFormat.standard,
          maxDuration: const Duration(seconds: 6),
          onSegment: segments.add);
      await cutter.attachDetector(EndingDetector());
      for (var offset = 0; offset < pcm.length; offset += chunkSize) {
        await cutter.add(Uint8List.sublistView(
            pcm, offset, (offset + chunkSize).clamp(0, pcm.length)));
      }
      cutter.flush();
      await cutter.dispose();
      return segments;
    }

    final small = await split(799);
    final large = await split(pcm.length);
    expect(small.first.length, 48 * 1024);
    expect(small, large);
    expect(small.expand((s) => s), pcm);
  });

  test('short utterances stay under the guest segment budget', () async {
    final segments = <Uint8List>[];
    final cutter = SentenceSegmenter(
        format: WavFormat.standard,
        maxDuration: const Duration(seconds: 6),
        onSegment: segments.add);
    await cutter.attachDetector(EndingDetector(frames: 1));
    await cutter.add(Uint8List(60 * 32000));
    cutter.flush();
    await cutter.dispose();
    expect(segments.length, lessThanOrEqualTo(64));
    expect(segments.take(segments.length - 1).every((s) => s.length >= 32000),
        isTrue);
    expect(segments.fold<int>(0, (sum, s) => sum + s.length), 60 * 32000);
  });

  test('continuous speech and failed inference keep bounded, lossless fallback',
      () async {
    for (final detector in [
      EndingDetector(frames: 1000),
      EndingDetector(fail: true)
    ]) {
      final segments = <Uint8List>[];
      final cutter = SentenceSegmenter(
          format: WavFormat.standard,
          maxDuration: const Duration(seconds: 6),
          onSegment: segments.add);
      await cutter.attachDetector(detector);
      final pcm = Uint8List(13 * 32000);
      await cutter.add(pcm);
      cutter.flush();
      await cutter.dispose();
      expect(segments.every((s) => s.length <= 6 * 32000), isTrue);
      expect(segments.expand((s) => s), pcm);
      expect(detector.disposed, isTrue);
    }
  });

  test('a model ready after disposal is released', () async {
    final detector = EndingDetector();
    final cutter = SentenceSegmenter(
        format: WavFormat.standard,
        maxDuration: const Duration(seconds: 6),
        onSegment: (_) {});
    await cutter.dispose();
    await cutter.attachDetector(detector);
    expect(detector.disposed, isTrue);
  });
}
