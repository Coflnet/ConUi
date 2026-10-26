import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/models/event.dart';
import 'package:relationship_manager/services/dia_sentence.dart';

RecordingTranscriptSlice slice(int start, int end, String text) =>
    RecordingTranscriptSlice(startByte: start, endByte: end, text: text);

void main() {
  test('silent markers do not shift repeated-sentence text selection', () {
    final sentences = detectDiaSentences([
      slice(0, 32000, 'Gleicher Satz.'),
      slice(32000, 64000, ''),
      slice(64000, 96000, 'Gleicher Satz.'),
    ]);
    expect(sentences.map((s) => s.recordingTextStart), [0, 15]);
    expect(sentences.map((s) => s.recordingTextEnd), [14, 29]);
    expect(sentences.last.contextText, 'Gleicher Satz.');
    expect(sentences.last.startByte, 64000);
    expect(sentences.last.endByte, 96000);
  });

  test(
      'identical sentences retain distinct global offsets across slices and gaps',
      () {
    for (final secondStart in [32000, 64000]) {
      final slices = [
        slice(0, 32000, 'Gleicher Satz.'),
        slice(secondStart, secondStart + 32000, 'Gleicher Satz.'),
      ];
      final sentences = detectDiaSentences(slices);
      expect(sentences.map((s) => s.recordingTextStart), [0, 15]);
      expect(sentences.map((s) => s.recordingTextEnd), [14, 29]);
      expect(sentences[1].startByte, secondStart);
      expect(sentences[1].contextText, 'Gleicher Satz.');
    }
  });

  test(
      'global text offsets preserve whitespace and separators across byte gaps',
      () {
    final slices = [
      slice(0, 32000, '  Anfang.\n '),
      slice(32000, 64000, ' Mitte!  Noch'),
      slice(64000, 96000, ' ein Satz. '),
      slice(128000, 160000, '\n Ende?  '),
    ];
    final text = slices.map((slice) => slice.text).join(' ');
    final sentences = detectDiaSentences(slices);
    for (final sentence in sentences) {
      expect(
          text.substring(
              sentence.recordingTextStart, sentence.recordingTextEnd),
          sentence.text);
    }
    expect(sentences[1].recordingTextStart, text.indexOf('Mitte'));
    expect(sentences[2].recordingTextStart, text.indexOf('Noch'));
    expect(sentences.last.recordingTextStart, text.indexOf('Ende'));
    expect(sentences.last.recordingTextEnd, text.indexOf('?') + 1);
    expect(sentences.last.textStart, 2);
    expect(sentences.last.startByte, 128000);
  });

  test('edits one sentence while preserving its whole slice context exactly',
      () {
    const text = '  Erster Satz.  Falsches Wort!\nLetzter Satz?  ';
    final sentences = detectDiaSentences([slice(32000, 192000, text)]);
    expect(sentences.map((s) => s.text),
        ['Erster Satz.', 'Falsches Wort!', 'Letzter Satz?']);
    final selected = sentences[1];
    expect(selected.contextText, text);
    expect(selected.startByte, 32000);
    expect(selected.endByte, 192000);
    expect(selected.textStart, text.indexOf('Falsches'));
    expect(selected.textEnd, text.indexOf('!') + 1);
    expect(selected.replaceWith('Richtiges Wort!'),
        '  Erster Satz.  Richtiges Wort!\nLetzter Satz?  ');
  });

  test('sentences span contiguous slices without inventing audio timestamps',
      () {
    final sentences = detectDiaSentences([
      slice(0, 192000, 'Schon fertig. Dieser Satz beginnt'),
      slice(192000, 384000, 'hier und endet jetzt. Danach folgt'),
      slice(384000, 576000, 'noch ein Satz.'),
    ]);
    expect(sentences.map((s) => s.text), [
      'Schon fertig.',
      'Dieser Satz beginnt hier und endet jetzt.',
      'Danach folgt noch ein Satz.',
    ]);
    expect(sentences.first.startByte, 0);
    expect(sentences.first.endByte, 192000);
    expect(sentences[1].startByte, 0);
    expect(sentences[1].endByte, 384000);
    expect(sentences[1].replaceWith('Dieser Satz stimmt.'),
        'Schon fertig. Dieser Satz stimmt. Danach folgt');
    expect(sentences.last.startByte, 192000);
    expect(sentences.last.endByte, 576000);
  });

  test('gaps never join text across failed or unknown audio', () {
    final sentences = detectDiaSentences([
      slice(0, 192000, 'Ein Satz ohne Ende'),
      slice(384000, 576000, 'Ein anderer Satz.'),
    ]);
    expect(sentences.map((s) => s.text),
        ['Ein Satz ohne Ende', 'Ein anderer Satz.']);
    expect(sentences.first.endByte, 192000);
    expect(sentences.last.contextText, 'Ein anderer Satz.');
    expect(sentences.last.startByte, 384000);
  });

  test('German and English abbreviations, initials and decimals remain intact',
      () {
    final sentences = detectDiaSentences([
      slice(0, 192000,
          'Dr. Müller kauft z. B. 3.14 Liter. Mr. Smith trifft A. Miller! Weiter?'),
    ]);
    expect(sentences.map((s) => s.text), [
      'Dr. Müller kauft z. B. 3.14 Liter.',
      'Mr. Smith trifft A. Miller!',
      'Weiter?',
    ]);
  });

  test('newlines and quoted punctuation delimit sentences without losing text',
      () {
    final sentences = detectDiaSentences([
      slice(
          0, 32000, 'Er sagte: „Ja!“ Danach?\nNoch ohne Punkt\n\nLetzte Zeile'),
    ]);
    expect(sentences.map((s) => s.text),
        ['Er sagte: „Ja!“', 'Danach?', 'Noch ohne Punkt', 'Letzte Zeile']);
    expect(sentences[2].replaceWith('Eine Korrektur'),
        'Er sagte: „Ja!“ Danach?\nEine Korrektur\n\nLetzte Zeile');
  });

  test('empty input and whitespace produce no invented sentences', () {
    expect(detectDiaSentences([]), isEmpty);
    expect(detectDiaSentences([slice(0, 32, ' \n ')]), isEmpty);
  });
}
