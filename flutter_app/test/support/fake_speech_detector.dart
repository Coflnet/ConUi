import 'dart:typed_data';

import 'package:relationship_manager/services/sentence_segmenter.dart';

class EndingDetector implements SpeechDetector {
  final int frames;
  final bool fail;
  int count = 0;
  bool disposed = false;
  EndingDetector({this.frames = 48, this.fail = false});
  @override
  Future<bool> speechEnded(Uint8List frame) async {
    if (fail) throw StateError('inference unavailable');
    return ++count >= frames;
  }

  @override
  void reset() => count = 0;
  @override
  Future<void> dispose() async {
    disposed = true;
    if (fail) throw StateError('release unavailable');
  }
}
