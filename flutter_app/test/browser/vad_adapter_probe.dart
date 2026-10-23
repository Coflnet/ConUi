// Manual browser regression entry point. The runner supplies synthetic PCM
// through a loopback route; no fixture or private dependency is packaged.
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
      child: Text('Local VAD adapter regression')));
  final cuts = <int>[];
  final emitted = BytesBuilder();
  var stage = 'model';
  final segmenter = SentenceSegmenter(
      format: WavFormat.standard,
      maxDuration: const Duration(seconds: 6),
      onSegment: (pcm) {
        cuts.add(pcm.length);
        emitted.add(pcm);
      });
  try {
    await segmenter.attachDetector(await DiaSpeechDetector.create());
    stage = 'fixture';
    final response = await http.get(Uri.base.resolve('vad-test.pcm'));
    if (response.statusCode != 200) {
      throw StateError('Synthetic fixture unavailable');
    }
    final pcm =
        Uint8List.fromList([...response.bodyBytes, ...Uint8List(32000)]);
    stage = 'frames';
    for (var offset = 0; offset < pcm.length; offset += 3200) {
      await segmenter.add(Uint8List.sublistView(
          pcm, offset, (offset + 3200).clamp(0, pcm.length)));
    }
    final beforeFlush = cuts.length;
    segmenter.flush();
    stage = 'cuts:$beforeFlush:${cuts.join(',')}';
    if (!listEquals(emitted.takeBytes(), pcm) ||
        beforeFlush == 0 ||
        !cuts.take(beforeFlush).any((size) => size < 5 * 32000)) {
      throw StateError('Speech-end segmentation or PCM preservation failed');
    }
    probeResult = 'pass:$beforeFlush:${cuts.join(',')}'.toJS;
  } catch (error) {
    probeResult = 'failed:$stage:${error.runtimeType}'.toJS;
  } finally {
    await segmenter.dispose();
  }
}
