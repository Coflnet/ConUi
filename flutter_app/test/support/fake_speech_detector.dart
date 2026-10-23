import 'dart:typed_data';

import 'package:relationship_manager/services/sentence_segmenter.dart';

class EndingDetector implements SpeechDetector {
  final int frames;
  final bool fail;
  final bool detectsSpeech;
  final int minSpeechFrames;
  int count = 0;
  bool disposed = false;
  EndingDetector(
      {this.frames = 48,
      this.fail = false,
      this.detectsSpeech = true,
      this.minSpeechFrames = 3});
  @override
  Future<bool> speechEnded(Uint8List frame) async {
    if (fail) throw StateError('inference unavailable');
    count++;
    return detectsSpeech && count >= frames;
  }

  @override
  bool get hasSpeech => detectsSpeech && count >= minSpeechFrames;

  @override
  void reset({bool continuing = false}) => count = 0;
  @override
  Future<void> dispose() async {
    disposed = true;
    if (fail) throw StateError('release unavailable');
  }
}
