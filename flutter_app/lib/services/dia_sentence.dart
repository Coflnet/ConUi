import '../models/event.dart';

/// A textual sentence with the complete original audio slices containing it.
/// Text offsets identify an edit within [contextText], never audio timing.
class DiaSentence {
  final String contextText;
  final int textStart, textEnd, startByte, endByte;

  /// Offsets into nonempty original slice texts joined with one space, across gaps.
  final int recordingTextStart, recordingTextEnd;

  const DiaSentence._(
      this.contextText,
      this.textStart,
      this.textEnd,
      this.startByte,
      this.endByte,
      this.recordingTextStart,
      this.recordingTextEnd);

  String get text => contextText.substring(textStart, textEnd);

  String replaceWith(String correction) =>
      contextText.replaceRange(textStart, textEnd, correction);
}

final _sentenceEnd = RegExp(r'''[.!?]+["'»“”’\)\]]*(?=\s|$)|\n+''');
final _wordBeforePeriod = RegExp(r'[A-Za-zÄÖÜäöüß]+$');
const _abbreviations = {
  'bzw',
  'ca',
  'dipl',
  'dr',
  'etc',
  'ggf',
  'hr',
  'inkl',
  'jr',
  'mrs',
  'mr',
  'ms',
  'nr',
  'prof',
  'sr',
  'st',
  'str',
  'usw',
  'vgl',
  'vs',
};

/// Gaps remain separate: text cannot stand in for missing or failed audio.
List<DiaSentence> detectDiaSentences(List<RecordingTranscriptSlice> slices) {
  final sentences = <DiaSentence>[];
  var group = <RecordingTranscriptSlice>[];
  var groupOffset = 0;
  var offset = 0;
  for (final slice in slices.where((slice) => slice.text.trim().isNotEmpty)) {
    if (group.isNotEmpty && group.last.endByte != slice.startByte) {
      sentences.addAll(_sentencesInGroup(group, groupOffset));
      group = [];
      groupOffset = offset;
    }
    group.add(slice);
    offset += slice.text.length + 1;
  }
  sentences.addAll(_sentencesInGroup(group, groupOffset));
  return sentences;
}

List<DiaSentence> _sentencesInGroup(
    List<RecordingTranscriptSlice> slices, int groupOffset) {
  final text = slices.map((slice) => slice.text).join(' ');
  final spans = <({RecordingTranscriptSlice slice, int start, int end})>[];
  var offset = 0;
  for (final slice in slices) {
    spans.add((slice: slice, start: offset, end: offset + slice.text.length));
    offset += slice.text.length + 1;
  }
  final sentences = <DiaSentence>[];
  var start = 0;
  void addSentence(int end) {
    final raw = text.substring(start, end);
    final trimmed = raw.trim();
    if (trimmed.isNotEmpty) {
      final textStart = start + raw.indexOf(trimmed);
      final textEnd = textStart + trimmed.length;
      final first = spans.firstWhere((span) => span.end > textStart);
      final last = spans.lastWhere((span) => span.start < textEnd);
      sentences.add(DiaSentence._(
          text.substring(first.start, last.end),
          textStart - first.start,
          textEnd - first.start,
          first.slice.startByte,
          last.slice.endByte,
          groupOffset + textStart,
          groupOffset + textEnd));
    }
    start = end;
  }

  for (final boundary in _sentenceEnd.allMatches(text)) {
    if (boundary.group(0)!.startsWith('.')) {
      final word = _wordBeforePeriod
          .firstMatch(text.substring(0, boundary.start))
          ?.group(0)
          ?.toLowerCase();
      if (word != null && (word.length == 1 || _abbreviations.contains(word))) {
        continue;
      }
    }
    addSentence(boundary.end);
  }
  addSentence(text.length);
  return sentences;
}
