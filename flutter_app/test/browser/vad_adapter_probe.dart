// Real-browser regression; the runner supplies synthetic PCM over loopback.
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:relationship_manager/services/sentence_segmenter.dart';
import 'package:relationship_manager/services/wav.dart';

@JS('vadAdapterProbeResult')
external set probeResult(JSString value);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const Directionality(
      textDirection: TextDirection.ltr,
      child: Text('Local VAD silence regression')));
  final segments = <(Uint8List, bool?)>[];
  var stage = 'model';
  final reports = <String>[];
  final segmenter = SentenceSegmenter(
      format: WavFormat.standard,
      maxDuration: const Duration(seconds: 6),
      onSegment: (bytes, speech) => segments.add((bytes, speech)));
  try {
    await segmenter.attachDetector(await DiaSpeechDetector.create());
    stage = 'fixture';
    final response = await http.get(Uri.base.resolve('vad-test.pcm'));
    if (response.statusCode != 200) {
      throw StateError('Synthetic fixture unavailable');
    }
    final source = response.bodyBytes;
    Future<void> check(String name, Uint8List pcm,
        {bool saved = false,
        bool continuing = false,
        bool quiet = false,
        bool speech = false,
        bool quietTail = false}) async {
      stage = name;
      segments.clear();
      if (!continuing) await segmenter.resetSpeechContext();
      for (var offset = 0; offset < pcm.length; offset += 3200) {
        await segmenter.add(
            Uint8List.sublistView(
                pcm, offset, (offset + 3200).clamp(0, pcm.length)),
            allowCuts: !saved);
      }
      await segmenter.flush();
      final emitted = BytesBuilder();
      for (final segment in segments) {
        emitted.add(segment.$1);
      }
      final flags = segments
          .map((s) => s.$2 == true
              ? 't'
              : s.$2 == false
                  ? 'f'
                  : 'u')
          .join();
      stage = '$name:$flags:${segments.map((s) => s.$1.length).join(',')}';
      if (!listEquals(emitted.takeBytes(), pcm) ||
          saved && segments.length != 1 ||
          quiet && segments.any((s) => s.$2 != false) ||
          speech && !segments.any((s) => s.$2 == true) ||
          quietTail && segments.last.$2 != false) {
        throw StateError('Speech eligibility or original PCM differs');
      }
      reports.add(stage);
    }

    await check('silence', Uint8List(13 * 32000), quiet: true);
    final noise = Uint8List(3 * 32000);
    final noiseSamples = ByteData.sublistView(noise);
    var seed = 7;
    for (var i = 0; i < noise.length; i += 2) {
      seed = (seed * 1664525 + 1013904223) & 0xffffffff;
      noiseSamples.setInt16(i, (seed % 129) - 64, Endian.little);
    }
    await check('quiet-noise', noise, quiet: true);
    final mixed = Uint8List.fromList([...source, ...Uint8List(3 * 32000)]);
    await check('speech-tail', mixed, speech: true, quietTail: true);
    await check('saved-silence', Uint8List(32014), saved: true, quiet: true);
    await check('saved-speech', mixed, saved: true, speech: true);
    // Select a high-energy 64ms window within the first two seconds of
    // actual synthetic speech, retaining its original preceding context.
    var loudest = 0.0;
    var cut = 24 * 1024;
    final samples = ByteData.sublistView(source);
    for (var start = cut; start + 2048 <= 64000; start += 1024) {
      var energy = 0.0;
      for (var i = start; i < start + 2048; i += 2) {
        final sample = samples.getInt16(i, Endian.little);
        energy += sample * sample;
      }
      if (energy > loudest) {
        loudest = energy;
        cut = start;
      }
    }
    await check('continuous-prefix', Uint8List.sublistView(source, 0, cut),
        saved: true, speech: true);
    await check(
        'continuous-short-tail', Uint8List.sublistView(source, cut, cut + 2048),
        saved: true, continuing: true, speech: true);
    await check('partial-silence', Uint8List(14),
        saved: true, continuing: true, quiet: true);
    stage = 'dispose';
    await segmenter.dispose();
    probeResult = 'pass:${reports.join(';')};disposed'.toJS;
  } catch (error) {
    probeResult = 'failed:$stage:${error.runtimeType}'.toJS;
  } finally {
    await segmenter.dispose();
  }
}
