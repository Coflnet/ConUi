import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/services/sentence_segmenter.dart';
import 'package:relationship_manager/services/wav.dart';

import '../support/fake_speech_detector.dart';

class _PcmDetector implements SpeechDetector {
  int positives = 0;
  int quiet = 0;
  bool qualified = false;
  @override
  bool get hasSpeech => qualified;
  @override
  Future<bool> speechEnded(Uint8List frame) async {
    if (frame.any((byte) => byte != 0)) {
      positives++;
      quiet = 0;
      if (positives >= 3) qualified = true;
    } else {
      quiet++;
    }
    return qualified && quiet >= 16;
  }

  @override
  void reset({bool continuing = false}) {
    positives = 0;
    quiet = 0;
    qualified = false;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  test('speech emits after 512ms silence without waiting for duration fallback', () async {
    final segments = <Uint8List>[];
    final cutter = SentenceSegmenter(
        format: WavFormat.standard,
        maxDuration: const Duration(seconds: 6),
        onSegment: (bytes, speech) {
          expect(speech, isTrue);
          segments.add(bytes);
        });
    await cutter.attachDetector(_PcmDetector());
    await cutter.add(Uint8List.fromList(List.filled(16 * 1024, 1)));
    await cutter.add(Uint8List(15 * 1024));
    expect(segments, isEmpty);
    await cutter.add(Uint8List(1024));
    expect(segments.single.length, 32 * 1024); // 1.024s total audio.
    await cutter.dispose();
  });

  test(
      'speech ends cut before six seconds with identical bytes across chunk sizes',
      () async {
    final pcm = Uint8List.fromList(List.generate(3 * 32000, (i) => i % 256));
    Future<List<Uint8List>> split(int chunkSize) async {
      final segments = <Uint8List>[];
      final cutter = SentenceSegmenter(
          format: WavFormat.standard,
          maxDuration: const Duration(seconds: 6),
          onSegment: (bytes, _) => segments.add(bytes));
      await cutter.attachDetector(EndingDetector());
      for (var offset = 0; offset < pcm.length; offset += chunkSize) {
        await cutter.add(Uint8List.sublistView(
            pcm, offset, (offset + chunkSize).clamp(0, pcm.length)));
      }
      await cutter.flush();
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
        onSegment: (bytes, _) => segments.add(bytes));
    await cutter.attachDetector(EndingDetector(frames: 1));
    await cutter.add(Uint8List(60 * 32000));
    await cutter.flush();
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
          onSegment: (bytes, _) => segments.add(bytes));
      await cutter.attachDetector(detector);
      final pcm = Uint8List(13 * 32000);
      await cutter.add(pcm);
      await cutter.flush();
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
        onSegment: (_, __) {});
    await cutter.dispose();
    await cutter.attachDetector(detector);
    expect(detector.disposed, isTrue);
  });

  test(
      'complete silence is classified false, including partial inference frames',
      () async {
    for (final length in [14, 13 * 32000]) {
      final emitted = BytesBuilder();
      final decisions = <bool?>[];
      final cutter = SentenceSegmenter(
          format: WavFormat.standard,
          maxDuration: const Duration(seconds: 6),
          onSegment: (bytes, speech) {
            emitted.add(bytes);
            decisions.add(speech);
          });
      await cutter.attachDetector(_PcmDetector());
      final pcm = Uint8List(length);
      await cutter.add(pcm);
      await cutter.flush();
      await cutter.dispose();
      expect(decisions, isNotEmpty);
      expect(decisions.every((speech) => speech == false), isTrue);
      expect(emitted.takeBytes(), pcm);
    }
  });

  test('speech is eligible while its long trailing silence is not', () async {
    final segments = <(Uint8List, bool?)>[];
    final cutter = SentenceSegmenter(
        format: WavFormat.standard,
        maxDuration: const Duration(seconds: 6),
        onSegment: (bytes, speech) => segments.add((bytes, speech)));
    await cutter.attachDetector(_PcmDetector());
    final pcm = Uint8List.fromList(
        [...List.filled(2 * 32000, 1), ...Uint8List(8 * 32000)]);
    await cutter.add(pcm);
    await cutter.flush();
    await cutter.dispose();
    expect(segments.first.$2, isTrue);
    expect(segments.skip(1).every((segment) => segment.$2 == false), isTrue);
    expect(segments.expand((segment) => segment.$1), pcm);
  });

  test('speech in quiet-cut lookahead does not qualify the preceding silence',
      () async {
    final segments = <(Uint8List, bool?)>[];
    final cutter = SentenceSegmenter(
        format: WavFormat.standard,
        maxDuration: const Duration(seconds: 6),
        onSegment: (bytes, speech) => segments.add((bytes, speech)));
    await cutter.attachDetector(_PcmDetector());
    final pcm =
        Uint8List.fromList([...Uint8List(176000), ...List.filled(16000, 1)]);
    await cutter.add(pcm);
    await cutter.flush();
    await cutter.dispose();
    expect(segments.first.$1.length, 5 * 32000);
    expect(segments.first.$2, isFalse);
    expect(segments.last.$2, isTrue);
    expect(segments.expand((segment) => segment.$1), pcm);
  });

  test('loading and failed models leave unknown segments for retry', () async {
    for (final failed in [false, true]) {
      final decisions = <bool?>[];
      final cutter = SentenceSegmenter(
          format: WavFormat.standard,
          maxDuration: const Duration(seconds: 6),
          onSegment: (_, speech) => decisions.add(speech));
      if (failed) await cutter.attachDetector(EndingDetector(fail: true));
      await cutter.add(Uint8List(6 * 32000));
      expect(decisions, [null]);
      await cutter.attachDetector(_PcmDetector());
      await cutter.flush();
      await cutter.dispose();
      expect(decisions, [null, false]);
    }
  });

  test(
      'authoritative saved slices retain their exact boundary during classification',
      () async {
    final segments = <(Uint8List, bool?)>[];
    final cutter = SentenceSegmenter(
        format: WavFormat.standard,
        maxDuration: const Duration(seconds: 6),
        onSegment: (bytes, speech) => segments.add((bytes, speech)));
    await cutter.attachDetector(_PcmDetector());
    final pcm = Uint8List.fromList([
      ...List.filled(2 * 32000, 1),
      ...Uint8List(32000),
      ...List.filled(2 * 32000, 1),
      ...Uint8List(2 * 32000)
    ]);
    await cutter.add(pcm, allowCuts: false);
    expect(segments, isEmpty);
    await cutter.flush();
    expect(segments, hasLength(1));
    expect(segments.single.$1, pcm);
    expect(segments.single.$2, isTrue);
    await cutter.add(Uint8List(14), allowCuts: false);
    await cutter.flush();
    await cutter.dispose();
    expect(segments.last.$2, isFalse);
    expect(segments.last.$1, Uint8List(14));
  });
}
