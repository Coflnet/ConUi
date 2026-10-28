import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/services/dia_contribution_client.dart';
import 'package:relationship_manager/services/dia_region_service.dart';
import 'package:relationship_manager/services/transcription_client.dart';
import 'package:relationship_manager/services/recording_file_store.dart';
import 'package:relationship_manager/services/wav.dart';
import 'package:relationship_manager/widgets/dia_correction_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_speech_detector.dart';

class _Store implements RecordingFileStore {
  final Uint8List original;
  int reads = 0;
  bool available = true;
  final int chunkSize;
  _Store(this.original, {this.chunkSize = 37});
  @override
  Future<int> size(String id) async {
    if (!available) throw StateError('Recording missing');
    return original.length;
  }

  @override
  Stream<List<int>> openReadStream(String id) async* {
    reads++;
    for (var offset = 0; offset < original.length; offset += chunkSize) {
      yield Uint8List.sublistView(
          original, offset, (offset + chunkSize).clamp(0, original.length));
    }
  }

  // Whole-file reads, mutation and deletion fail the test immediately.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected store operation: ${invocation.memberName}');
}

void main() {
  late _Store store;
  late AttachedFile file;
  late List<http.Request> requests;
  late DiaContributionClient client;
  var failUpload = false;
  var failPolicy = false;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    failUpload = false;
    failPolicy = false;
    requests = [];
    store = _Store(WavHeader.wrap(
        Uint8List.fromList(List.generate(200, (index) => index))));
    file = AttachedFile(
      id: 'original',
      fileName: 'original.wav',
      filePath: 'original',
      mimeType: 'audio/wav',
      size: store.original.length,
      kind: AttachedFile.kindRecording,
      transcriptSlices: const [
        RecordingTranscriptSlice(
            startByte: 0, endByte: 100, text: 'First sentence.'),
        RecordingTranscriptSlice(
            startByte: 100, endByte: 200, text: 'Second sentence.'),
      ],
    );
    client = DiaContributionClient(httpClient: MockClient((request) async {
      requests.add(request);
      if (request.method == 'GET') {
        if (failPolicy) return http.Response('unavailable', 503);
        return http.Response(
            jsonEncode({
              'version': 'current',
              'information': 'Current privacy information',
              'terms': 'Current contribution terms',
              'privacyUrl': 'https://coflnet.com/de/privacy/',
              'purposes': [
                {
                  'value': 4,
                  'title': 'Speech training',
                  'description': 'Coflnet only'
                },
              ],
            }),
            200);
      }
      if (request.url.path.endsWith('/consents')) {
        return http.Response(
            '{"id":"consent-id","contributorAlias":"device@dia.invalid","purposes":4}',
            200);
      }
      return failUpload
          ? http.Response('unavailable', 503)
          : http.Response('{"id":"deletion-reference"}', 200);
    }));
  });

  Future<void> open(WidgetTester tester,
      {String language = 'en',
      double width = 1000,
      bool settle = true,
      TextEditingValue? source,
      Future<DiaRegion?> Function()? regionSuggestion,
      Future<List<RecordingTranscriptSlice>?> Function()?
          loadOriginalTranscript,
      TranscriptionClient? transcriptionClient,
      Future<void> Function(List<RecordingTranscriptSlice>)?
          onTranscriptDetected}) async {
    tester.view.physicalSize = Size(width, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      locale: Locale(language),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                    onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => DiaCorrectionDialog(
                            file: file,
                            store: store,
                            client: client,
                            source: source,
                            loadOriginalTranscript: loadOriginalTranscript,
                            regionSuggestion:
                                regionSuggestion ?? () async => null,
                            transcriptionClient: transcriptionClient,
                            createSpeechDetector: () async =>
                                EndingDetector(minSpeechFrames: 1),
                            onTranscriptDetected: onTranscriptDetected,
                            language: language)),
                    child: const Text('Open'),
                  ))),
    ));
    await tester.tap(find.text('Open'));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
  }

  Future<void> agreeAndSend(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const Key('dia-consent')));
    await tester.tap(find.byKey(const Key('dia-consent')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dia-submit')));
    await tester.pumpAndSettle();
  }

  Future<void> showWordMenu(
      WidgetTester tester, String text, int wordStart, int wordEnd) async {
    final controller = TextEditingController(text: text);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(
          body: Padding(
        padding: const EdgeInsets.all(40),
        child: TextField(
            key: const Key('story-editor'),
            controller: controller,
            contextMenuBuilder: (context, editable) => diaCorrectionTextMenu(
                context, editable,
                recordings: [file], store: store)),
      )),
    ));
    await tester.tap(find.byKey(const Key('story-editor')));
    controller.selection =
        TextSelection(baseOffset: wordStart, extentOffset: wordEnd);
    await tester.pumpAndSettle();
    final editable = tester.state<EditableTextState>(find.byType(EditableText));
    expect(editable.showToolbar(), isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
  }

  testWidgets(
      'real text selection menu opens editor for exactly the selected word',
      (tester) async {
    SharedPreferences.setMockInitialValues({'dia-region-country': 'DE'});
    const story = 'Notes. First sentence. Second sentence.';
    final start = story.indexOf('Second');
    await http.runWithClient(() async {
      await showWordMenu(tester, story, start, start + 'Second'.length);
      final context = tester.element(find.byKey(const Key('story-editor')));
      await tester.tap(find.text(AppLocalizations.of(context).diaCorrectWord));
      await tester.pumpAndSettle();
      expect(find.byType(DiaCorrectionDialog), findsOneWidget);
      final controller = tester
          .widget<TextField>(find.byKey(const Key('dia-correction')))
          .controller!;
      expect(controller.text, 'Second sentence.');
      expect(controller.selection,
          const TextSelection(baseOffset: 0, extentOffset: 6));
      expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
      expect(requests.where((request) => request.method == 'POST'), isEmpty);
      expect(store.reads, 0);
    },
        () => MockClient((request) async {
              requests.add(request);
              return http.Response('{}', 503);
            }));
  });

  for (final ambiguous in [false, true]) {
    testWidgets(
        'real text selection menu omits Dia for ${ambiguous ? 'ambiguous' : 'unrelated'} text',
        (tester) async {
      final story = ambiguous ? 'Notes. Wrong word.' : 'Unrelated story word.';
      if (ambiguous) {
        file.transcriptSlices = const [
          RecordingTranscriptSlice(
              startByte: 0, endByte: 100, text: 'Wrong word.'),
          RecordingTranscriptSlice(
              startByte: 100, endByte: 200, text: 'Wrong word.'),
        ];
      }
      final start = story.indexOf('word');
      await showWordMenu(tester, story, start, start + 4);
      final context = tester.element(find.byKey(const Key('story-editor')));
      expect(
          find.text(AppLocalizations.of(context).diaCorrectWord), findsNothing);
      expect(find.byType(DiaCorrectionDialog), findsNothing);
      expect(requests, isEmpty);
      expect(store.reads, 0);
    });
  }

  testWidgets(
      'opening prefills matched sentence, consent is off, cancel never uploads',
      (tester) async {
    await open(tester);
    final correction =
        tester.widget<TextField>(find.byKey(const Key('dia-correction')));
    expect(correction.controller!.text, 'First sentence.');
    expect(
        tester
            .widget<CheckboxListTile>(find.byKey(const Key('dia-consent')))
            .value,
        false);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('dia-submit')))
            .onPressed,
        isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(DiaCorrectionDialog), findsNothing);
    expect(requests.where((request) => request.method == 'POST'), isEmpty);
    expect(store.reads, 0);
  });

  testWidgets(
      'second sentence sends exact original samples and receipt without mutation',
      (tester) async {
    final original = Uint8List.fromList(store.original);
    final originalModel = jsonEncode(file.toJson());
    await open(tester);
    await tester.tap(find.byKey(const Key('dia-sentences')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dia-sentence-1')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('dia-correction')))
            .controller!
            .text,
        'Second sentence.');
    await tester.enterText(
        find.byKey(const Key('dia-correction')), 'Second corrected sentence.');
    await agreeAndSend(tester);
    final upload =
        requests.singleWhere((request) => request.url.path.endsWith('/upload'));
    final body = jsonDecode(upload.body) as Map;
    expect(body['transcription'], 'Second corrected sentence.');
    expect(base64Decode(body['base64Audio'] as String),
        WavHeader.wrap(Uint8List.sublistView(original, wavHeaderLength + 100)));
    expect(find.text('deletion-reference'), findsOneWidget);
    expect(store.original, original);
    expect(jsonEncode(file.toJson()), originalModel);
  });

  testWidgets('failed upload keeps correction and allows explicit retry',
      (tester) async {
    failUpload = true;
    await open(tester);
    await tester.enterText(
        find.byKey(const Key('dia-correction')), 'Keep my correction.');
    await agreeAndSend(tester);
    expect(find.byKey(const Key('dia-error')), findsOneWidget);
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('dia-correction')))
            .controller!
            .text,
        'Keep my correction.');
    failUpload = false;
    await tester.tap(find.byKey(const Key('dia-submit')));
    await tester.pumpAndSettle();
    expect(find.text('deletion-reference'), findsOneWidget);
    expect(requests.where((request) => request.url.path.endsWith('/upload')),
        hasLength(2));
  });

  testWidgets('leaving or changing sentences protects an unsent correction',
      (tester) async {
    await open(tester);
    await tester.enterText(
        find.byKey(const Key('dia-correction')), 'Unsent correction');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Discard this unsent correction?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('dia-sentences')));
    await tester.tap(find.byKey(const Key('dia-sentences')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('dia-sentence-1')));
    await tester.tap(find.byKey(const ValueKey('dia-sentence-1')));
    await tester.pumpAndSettle();
    expect(find.text('Discard this unsent correction?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('dia-correction')))
            .controller!
            .text,
        'Unsent correction');
    expect(requests.where((request) => request.method == 'POST'), isEmpty);
  });

  testWidgets(
      'legacy recordings offer editable ranges capped at twenty seconds',
      (tester) async {
    file = AttachedFile(
        id: 'legacy',
        fileName: 'old.wav',
        filePath: 'legacy',
        mimeType: 'audio/wav',
        size: 1,
        kind: AttachedFile.kindRecording);
    store = _Store(
        WavHeader.wrap(Uint8List(90 * WavFormat.standard.bytesPerSecond)));
    await open(tester);
    var slider =
        tester.widget<RangeSlider>(find.byKey(const Key('dia-audio-range')));
    expect(slider.values, const RangeValues(0, 20));
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('dia-correction')))
            .controller!
            .text,
        isEmpty);
    slider.onChanged!(const RangeValues(0, 90));
    await tester.pumpAndSettle();
    slider =
        tester.widget<RangeSlider>(find.byKey(const Key('dia-audio-range')));
    expect(slider.values, const RangeValues(70, 90));
    expect(store.reads, 0);
    expect(requests.where((request) => request.method == 'POST'), isEmpty);
  });

  testWidgets(
      'oversized timed sentence explains limit without cutting or posting',
      (tester) async {
    file.transcriptSlices = const [
      RecordingTranscriptSlice(
          startByte: 0, endByte: 21 * 32000, text: 'Long sentence.')
    ];
    store = _Store(WavHeader.wrap(Uint8List(21 * 32000)));
    await open(tester);
    await tester.ensureVisible(find.byKey(const Key('dia-consent')));
    await tester.tap(find.byKey(const Key('dia-consent')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dia-clip-too-long')), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('dia-submit')))
            .onPressed,
        isNull);
    expect(store.reads, 0);
    expect(requests.where((request) => request.method == 'POST'), isEmpty);
  });

  testWidgets('missing recording during opening shows an audio recovery error',
      (tester) async {
    store.available = false;
    await open(tester);
    expect(tester.widget<Text>(find.byKey(const Key('dia-error'))).data,
        startsWith('Could not read or play this audio.'));
    expect(requests, isEmpty);
  });

  testWidgets(
      'recording lost before sending keeps correction and reports audio failure',
      (tester) async {
    await open(tester);
    await tester.enterText(
        find.byKey(const Key('dia-correction')), 'Keep this correction.');
    store.available = false;
    await agreeAndSend(tester);
    expect(tester.widget<Text>(find.byKey(const Key('dia-error'))).data,
        startsWith('Could not read or play this audio.'));
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('dia-correction')))
            .controller!
            .text,
        'Keep this correction.');
    expect(requests.where((request) => request.method == 'POST'), isEmpty);
  });

  testWidgets(
      'selected word chooses only its sentence and preserves original context audio',
      (tester) async {
    const contextText = 'First sentence. Second wrong sentence.';
    const story = 'Story introduction. $contextText';
    final start = story.indexOf('wrong');
    file.transcriptSlices = const [
      RecordingTranscriptSlice(startByte: 0, endByte: 200, text: contextText)
    ];
    final originalModel = jsonEncode(file.toJson());
    final original = Uint8List.fromList(store.original);
    await open(tester,
        source: TextEditingValue(
            text: story,
            selection:
                TextSelection(baseOffset: start, extentOffset: start + 5)));
    final correction = tester
        .widget<TextField>(find.byKey(const Key('dia-correction')))
        .controller!;
    expect(correction.text, 'Second wrong sentence.');
    expect(correction.selection.textInside(correction.text), 'wrong');
    expect(find.byKey(const ValueKey('dia-sentence-1')).hitTestable(),
        findsNothing);
    expect(
        tester
            .widget<CheckboxListTile>(find.byKey(const Key('dia-consent')))
            .value,
        false);
    expect(requests.where((request) => request.method == 'POST'), isEmpty);
    await tester.enterText(
        find.byKey(const Key('dia-correction')), 'Second right sentence.');
    await agreeAndSend(tester);
    final upload =
        requests.singleWhere((request) => request.url.path.endsWith('/upload'));
    final body = jsonDecode(upload.body) as Map;
    expect(body['transcription'], 'First sentence. Second right sentence.');
    expect(base64Decode(body['base64Audio'] as String), original);
    expect(store.original, original);
    expect(jsonEncode(file.toJson()), originalModel);
  });

  testWidgets(
      'selection in repeated sentence uses the second original audio slice',
      (tester) async {
    const story = 'Notes. Wrong word. Wrong word.';
    final start = story.lastIndexOf('word');
    file.transcriptSlices = const [
      RecordingTranscriptSlice(startByte: 0, endByte: 100, text: 'Wrong word.'),
      RecordingTranscriptSlice(
          startByte: 100, endByte: 200, text: 'Wrong word.'),
    ];
    final original = Uint8List.fromList(store.original);
    await open(tester,
        source: TextEditingValue(
            text: story,
            selection:
                TextSelection(baseOffset: start, extentOffset: start + 4)));
    final controller = tester
        .widget<TextField>(find.byKey(const Key('dia-correction')))
        .controller!;
    expect(controller.text, 'Wrong word.');
    expect(controller.selection.textInside(controller.text), 'word');
    await tester.enterText(
        find.byKey(const Key('dia-correction')), 'Wrong wording.');
    await agreeAndSend(tester);
    final upload =
        requests.singleWhere((request) => request.url.path.endsWith('/upload'));
    final body = jsonDecode(upload.body) as Map;
    expect(body['transcription'], 'Wrong wording.');
    expect(base64Decode(body['base64Audio'] as String),
        WavHeader.wrap(Uint8List.sublistView(original, wavHeaderLength + 100)));
    expect(store.original, original);
  });

  testWidgets(
      'repeated word keeps the exact selected occurrence within its sentence',
      (tester) async {
    const text = 'Das war, wie es war.';
    final start = text.lastIndexOf('war');
    file.transcriptSlices = const [
      RecordingTranscriptSlice(startByte: 0, endByte: 200, text: text)
    ];
    await open(tester,
        source: TextEditingValue(
            text: text,
            selection:
                TextSelection(baseOffset: start, extentOffset: start + 3)));
    final controller = tester
        .widget<TextField>(find.byKey(const Key('dia-correction')))
        .controller!;
    expect(controller.selection,
        TextSelection(baseOffset: start, extentOffset: start + 3));
    expect(
        controller.text.replaceRange(
            controller.selection.start, controller.selection.end, 'ist'),
        'Das war, wie es ist.');
    expect(requests.where((request) => request.method == 'POST'), isEmpty);
  });

  testWidgets(
      'ambiguous edited story keeps manual sentence choice without preselecting a word',
      (tester) async {
    const story = 'Notes. Wrong word.';
    final start = story.indexOf('word');
    file.transcriptSlices = const [
      RecordingTranscriptSlice(startByte: 0, endByte: 100, text: 'Wrong word.'),
      RecordingTranscriptSlice(
          startByte: 100, endByte: 200, text: 'Wrong word.'),
    ];
    await open(tester,
        source: TextEditingValue(
            text: story,
            selection:
                TextSelection(baseOffset: start, extentOffset: start + 4)));
    final controller = tester
        .widget<TextField>(find.byKey(const Key('dia-correction')))
        .controller!;
    expect(controller.selection.isCollapsed, true);
    expect(find.byKey(const Key('dia-sentences')), findsOneWidget);
    await tester.tap(find.byKey(const Key('dia-sentences')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dia-sentence-0')).hitTestable(),
        findsOneWidget);
    expect(find.byKey(const ValueKey('dia-sentence-1')).hitTestable(),
        findsOneWidget);
    expect(requests.where((request) => request.method == 'POST'), isEmpty);
  });

  for (final field in ['Postcode', 'Country code']) {
    for (final clear in [false, true]) {
      testWidgets(
          'late region default preserves ${clear ? 'cleared' : 'edited'} $field and fills untouched field',
          (tester) async {
        final suggestion = Completer<DiaRegion?>();
        await open(tester, regionSuggestion: () => suggestion.future);
        await tester.tap(find.text('Dialect region (optional)'));
        await tester.pumpAndSettle();
        final edited = find.widgetWithText(TextField, field);
        await tester.ensureVisible(edited);
        await tester.enterText(edited, field == 'Postcode' ? '90210' : 'US');
        if (clear) await tester.enterText(edited, '');
        suggestion.complete(const DiaRegion(zip: '10115', country: 'DE'));
        await tester.pumpAndSettle();
        expect(
            tester.widget<TextField>(edited).controller!.text,
            clear
                ? ''
                : field == 'Postcode'
                    ? '90210'
                    : 'US');
        final untouched = find.widgetWithText(
            TextField, field == 'Postcode' ? 'Country code' : 'Postcode');
        expect(tester.widget<TextField>(untouched).controller!.text,
            field == 'Postcode' ? 'DE' : '10115');
        expect(requests.where((request) => request.method == 'POST'), isEmpty);
      });
    }
  }

  for (final editedCountry in [null, 'AT']) {
    testWidgets(
        'sending waits for region and preserves country ${editedCountry ?? 'default'}',
        (tester) async {
      final suggestion = Completer<DiaRegion?>();
      await open(tester, regionSuggestion: () => suggestion.future);
      await tester.enterText(find.byKey(const Key('dia-correction')), 'Fixed.');
      if (editedCountry != null) {
        await tester.tap(find.text('Dialect region (optional)'));
        await tester.pumpAndSettle();
        final country = find.widgetWithText(TextField, 'Country code');
        await tester.ensureVisible(country);
        await tester.enterText(country, editedCountry);
      }
      await tester.ensureVisible(find.byKey(const Key('dia-consent')));
      await tester.tap(find.byKey(const Key('dia-consent')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('dia-submit')));
      await tester.pump();
      expect(requests.where((request) => request.method == 'POST'), isEmpty);
      expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('dia-submit')))
              .onPressed,
          isNull);
      suggestion.complete(const DiaRegion(zip: '80331', country: 'DE'));
      await tester.pumpAndSettle();
      final upload = requests
          .singleWhere((request) => request.url.path.endsWith('/upload'));
      final body = jsonDecode(upload.body) as Map;
      expect(body['zipCode'], '80331');
      expect(body['country'], editedCountry ?? 'DE');
      expect(body['transcription'], 'Fixed.');
      expect(find.text('deletion-reference'), findsOneWidget);
    });
  }

  testWidgets(
      'original saved mapping opens immediately without reading audio or ASR',
      (tester) async {
    var loads = 0, calls = 0;
    final asr = TranscriptionClient(
        baseUrl: 'https://con.example',
        getToken: () => null,
        httpClient: MockClient((_) async {
          calls++;
          throw StateError('Original mapping must be reused');
        }));
    addTearDown(asr.close);
    await open(tester, transcriptionClient: asr,
        loadOriginalTranscript: () async {
      loads++;
      throw StateError('Mapping already attached');
    });
    expect(loads, 0);
    expect(calls, 0);
    expect(store.reads, 0);
    expect(find.text('Detecting sentences in this recording…'), findsNothing);
  });

  for (final silent in [false, true]) {
    testWidgets(
        'local original ${silent ? 'silence' : 'sentence marks'} never invokes ASR',
        (tester) async {
      final original = silent
          ? const [
              RecordingTranscriptSlice(startByte: 0, endByte: 200, text: '')
            ]
          : file.transcriptSlices;
      file.transcriptSlices = [];
      var calls = 0;
      final asr = TranscriptionClient(
          baseUrl: 'https://con.example',
          getToken: () => null,
          httpClient: MockClient((_) async {
            calls++;
            throw StateError('Original mapping must be reused');
          }));
      addTearDown(asr.close);
      final saved = <List<RecordingTranscriptSlice>>[];
      await open(tester,
          transcriptionClient: asr,
          source: const TextEditingValue(
              text: 'First sentence. Second sentence.',
              selection: TextSelection(baseOffset: 16, extentOffset: 22)),
          loadOriginalTranscript: () async => original,
          onTranscriptDetected: (slices) async => saved.add(slices));
      expect(calls, 0);
      expect(store.reads, 0);
      expect(requests.where((request) => request.method == 'POST'), isEmpty);
      if (!silent) {
        expect(saved.single, original);
        expect(file.transcriptSlices, original);
        final correction = tester
            .widget<TextField>(find.byKey(const Key('dia-correction')))
            .controller!;
        expect(correction.text, 'Second sentence.');
        expect(correction.selection,
            const TextSelection(baseOffset: 0, extentOffset: 6));
      }
    });
  }

  testWidgets(
      'legacy analysis saves exact boundaries and reopening needs no ASR or training upload',
      (tester) async {
    file.transcriptSlices = [];
    final pcm = Uint8List.fromList(
        List.generate(6 * 32000 + 100, (index) => index % 251));
    store = _Store(WavHeader.wrap(pcm), chunkSize: 10000);
    final asrRequests = <http.Request>[];
    final asr = TranscriptionClient(
        baseUrl: 'https://con.example',
        getToken: () => null,
        httpClient: MockClient((request) async {
          asrRequests.add(request);
          return http.Response(
              jsonEncode({
                'text': asrRequests.length == 1
                    ? 'First detected sentence.'
                    : 'Second detected sentence.'
              }),
              200);
        }));
    final saved = <List<RecordingTranscriptSlice>>[];
    await open(tester,
        transcriptionClient: asr,
        onTranscriptDetected: (slices) async => saved.add(List.of(slices)));
    expect(asrRequests, hasLength(2));
    expect(asrRequests.map((request) => request.url.path),
        everyElement('/api/transcription/segment'));
    expect(asrRequests.first.bodyBytes,
        WavHeader.wrap(Uint8List.sublistView(pcm, 0, 6 * 32000)));
    expect(asrRequests.last.bodyBytes,
        WavHeader.wrap(Uint8List.sublistView(pcm, 6 * 32000)));
    expect(
        file.transcriptSlices
            .map((slice) => (slice.startByte, slice.endByte, slice.text)),
        [
          (0, 6 * 32000, 'First detected sentence.'),
          (6 * 32000, pcm.length, 'Second detected sentence.'),
        ]);
    expect(saved, hasLength(1));
    expect(saved.single, file.transcriptSlices);
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('dia-correction')))
            .controller!
            .text,
        'First detected sentence.');
    expect(
        tester
            .widget<CheckboxListTile>(find.byKey(const Key('dia-consent')))
            .value,
        false);
    expect(requests.where((request) => request.method == 'POST'), isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(asrRequests, hasLength(2));
    expect(saved, hasLength(1));
    expect(store.original, WavHeader.wrap(pcm));
  });

  testWidgets('saving marks retry preserves draft and does not repeat ASR',
      (tester) async {
    file.transcriptSlices = [];
    var asrCalls = 0, saves = 0;
    final asr = TranscriptionClient(
        baseUrl: 'https://con.example',
        getToken: () => null,
        httpClient: MockClient((_) async {
          asrCalls++;
          return http.Response('{"text":"Detected sentence."}', 200);
        }));
    await open(tester, transcriptionClient: asr,
        onTranscriptDetected: (_) async {
      if (saves++ == 0) throw StateError('Local storage unavailable');
    });
    expect(tester.widget<Text>(find.byKey(const Key('dia-error'))).data,
        startsWith('Sentence marks could not be saved.'));
    await tester.enterText(
        find.byKey(const Key('dia-correction')), 'Corrected draft.');
    await tester.ensureVisible(find.text('Retry'));
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(saves, 2);
    expect(asrCalls, 1);
    expect(file.transcriptSlices.single.text, 'Detected sentence.');
    expect(find.byKey(const Key('dia-error')), findsNothing);
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('dia-correction')))
            .controller!
            .text,
        'Corrected draft.');
    expect(requests.where((request) => request.method == 'POST'), isEmpty);
  });

  testWidgets(
      'policy retry survives delayed legacy detection and preserves its draft',
      (tester) async {
    file.transcriptSlices = [];
    failPolicy = true;
    final response = Completer<http.Response>();
    var asrCalls = 0;
    final asr = TranscriptionClient(
        baseUrl: 'https://con.example',
        getToken: () => null,
        httpClient: MockClient((_) {
          asrCalls++;
          return response.future;
        }));
    await open(tester, transcriptionClient: asr, settle: false);
    expect(requests.where((request) => request.method == 'GET'), hasLength(1));
    response.complete(http.Response('{"text":"Detected sentence."}', 200));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(DiaCorrectionDialog));
    final l10n = AppLocalizations.of(context);
    expect(tester.widget<Text>(find.byKey(const Key('dia-error'))).data,
        l10n.diaPolicyError);
    await tester.enterText(
        find.byKey(const Key('dia-correction')), 'Keep the edited draft.');
    failPolicy = false;
    await tester.ensureVisible(find.text(l10n.commonRetry));
    await tester.tap(find.text(l10n.commonRetry));
    await tester.pumpAndSettle();
    expect(asrCalls, 1);
    expect(requests.where((request) => request.method == 'GET'), hasLength(2));
    expect(find.byKey(const Key('dia-error')), findsNothing);
    expect(find.byKey(const Key('dia-consent')), findsOneWidget);
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('dia-correction')))
            .controller!
            .text,
        'Keep the edited draft.');
    expect(requests.where((request) => request.method == 'POST'), isEmpty);
  });

  testWidgets(
      'failed legacy detection retries transcription before any training consent',
      (tester) async {
    file.transcriptSlices = [];
    var calls = 0;
    final asr = TranscriptionClient(
        baseUrl: 'https://con.example',
        getToken: () => null,
        httpClient: MockClient((_) async => ++calls == 1
            ? http.Response(
                '{"slug":"transcription_failed","message":"unavailable"}', 502)
            : http.Response('{"text":"Recovered sentence."}', 200)));
    await open(tester, transcriptionClient: asr);
    expect(tester.widget<Text>(find.byKey(const Key('dia-error'))).data,
        startsWith('Could not detect sentences.'));
    expect(file.transcriptSlices, isEmpty);
    await tester.ensureVisible(find.text('Retry'));
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(file.transcriptSlices.single.text, 'Recovered sentence.');
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('dia-correction')))
            .controller!
            .text,
        'Recovered sentence.');
    expect(
        tester
            .widget<CheckboxListTile>(find.byKey(const Key('dia-consent')))
            .value,
        false);
    expect(requests.where((request) => request.method == 'POST'), isEmpty);
  });

  testWidgets(
      'anonymous analysis quota shows sign-in guidance without generic retry',
      (tester) async {
    file.transcriptSlices = [];
    final asr = TranscriptionClient(
        baseUrl: 'https://con.example',
        getToken: () => null,
        httpClient: MockClient((_) async => http.Response(
            '{"slug":"anonymous_daily_limit","message":"daily allowance reached"}',
            429)));
    await open(tester, transcriptionClient: asr);
    final dialogContext = tester.element(find.byType(DiaCorrectionDialog));
    final l10n = AppLocalizations.of(dialogContext);
    expect(tester.widget<Text>(find.byKey(const Key('dia-error'))).data,
        l10n.liveTranscriptionAnonymousLimit);
    expect(find.text(l10n.commonRetry), findsNothing);
    expect(file.transcriptSlices, isEmpty);
    expect(requests.where((request) => request.method == 'POST'), isEmpty);
  });

  testWidgets('authenticated daily quota has no guest sign-in guidance',
      (tester) async {
    file.transcriptSlices = [];
    final asr = TranscriptionClient(
        baseUrl: 'https://con.example',
        getToken: () => 'signed-in',
        httpClient: MockClient((_) async => http.Response(
            '{"slug":"transcription_daily_limit","message":"daily allowance reached"}',
            429)));
    await open(tester, transcriptionClient: asr);
    final l10n =
        AppLocalizations.of(tester.element(find.byType(DiaCorrectionDialog)));
    expect(tester.widget<Text>(find.byKey(const Key('dia-error'))).data,
        l10n.liveTranscriptionDailyLimit);
    expect(find.text(l10n.liveTranscriptionAnonymousLimit), findsNothing);
    expect(file.transcriptSlices, isEmpty);
  });

  for (final language in ['en', 'de']) {
    testWidgets('390px $language dialog scrolls terms without overflow',
        (tester) async {
      await open(tester, language: language, width: 390);
      await tester.ensureVisible(find.byKey(const Key('dia-terms')));
      await tester.tap(find.byKey(const Key('dia-terms')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('dia-consent')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(requests.where((request) => request.method == 'POST'), isEmpty);
    });
  }
}
