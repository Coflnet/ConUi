import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/services/dia_contribution_client.dart';
import 'package:relationship_manager/services/recording_file_store.dart';
import 'package:relationship_manager/services/wav.dart';
import 'package:relationship_manager/widgets/dia_correction_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Store implements RecordingFileStore {
  final Uint8List original;
  int reads = 0;
  bool available = true;
  _Store(this.original);
  @override
  Future<int> size(String id) async {
    if (!available) throw StateError('Recording missing');
    return original.length;
  }

  @override
  Stream<List<int>> openReadStream(String id) async* {
    reads++;
    for (var offset = 0; offset < original.length; offset += 37) {
      yield Uint8List.sublistView(
          original, offset, (offset + 37).clamp(0, original.length));
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

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    failUpload = false;
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
      {String language = 'en', double width = 1000}) async {
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
                            file: file, store: store, client: client)),
                    child: const Text('Open'),
                  ))),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  Future<void> agreeAndSend(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const Key('dia-consent')));
    await tester.tap(find.byKey(const Key('dia-consent')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dia-submit')));
    await tester.pumpAndSettle();
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
