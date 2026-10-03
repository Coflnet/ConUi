import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/services/recording_file_store.dart';
import 'package:relationship_manager/widgets/recording_player.dart';

class _Store implements RecordingFileStore {
  final Completer<PlaybackSource> source = Completer<PlaybackSource>();

  @override
  Future<PlaybackSource> openPlaybackSource(String id) => source.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final sinks = <String, MockStreamHandlerEventSink>{};
  late List<String> calls;
  String? failingMethod;
  Completer<void>? pendingResume;
  Completer<void>? pendingDispose;

  setUp(() {
    calls = [];
    sinks.clear();
    failingMethod = null;
    pendingResume = null;
    pendingDispose = null;
    messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers'), (call) async {
      calls.add(call.method);
      final id = (call.arguments as Map)['playerId'] as String;
      if (call.method == 'create') {
        messenger.setMockStreamHandler(
            EventChannel('xyz.luan/audioplayers/events/$id'),
            MockStreamHandler.inline(onListen: (_, sink) {
          sinks[id] = sink;
        }));
      }
      if (call.method == failingMethod) {
        throw PlatformException(code: 'AbortError', message: 'Media removed');
      }
      if (call.method == 'setSourceUrl') {
        sinks[id]!.success({'event': 'audio.onPrepared', 'value': true});
      }
      if (call.method == 'resume' && pendingResume != null) {
        await pendingResume!.future;
      }
      if (call.method == 'dispose' && pendingDispose != null) {
        await pendingDispose!.future;
      }
      return null;
    });
  });

  Future<void> showPlayer(WidgetTester tester, _Store store) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('de'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
          body: RecordingPlayer(
        file: AttachedFile(
            id: 'rec',
            fileName: 'Erzählung.wav',
            filePath: 'rec',
            mimeType: 'audio/wav',
            size: 100,
            durationMs: 10000,
            kind: AttachedFile.kindRecording),
        store: store,
      )),
    ));
    await tester.pump();
  }

  Future<void> loadPlayer(WidgetTester tester, _Store store,
      {void Function()? onRelease}) async {
    store.source.complete(
        PlaybackSource.objectUrl('blob:recording', onRelease ?? () {}));
    await showPlayer(tester, store);
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsOneWidget);
  }

  for (final operation in ['resume', 'pause', 'seek']) {
    testWidgets('$operation failure shows the localized error without escaping',
        (tester) async {
      await loadPlayer(tester, _Store());
      if (operation == 'pause') {
        await tester.tap(find.byIcon(Icons.play_circle_filled));
        await tester.pumpAndSettle();
      }
      failingMethod = operation;
      if (operation == 'seek') {
        tester.widget<Slider>(find.byType(Slider)).onChanged!(5000);
      } else {
        await tester.tap(find.byType(IconButton));
      }
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      final context = tester.element(find.byType(RecordingPlayer));
      expect(
          find.text(AppLocalizations.of(context).recordingPlayerFailedToLoad),
          findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }

  testWidgets('source arriving after disposal is released and never prepared',
      (tester) async {
    final store = _Store();
    var releases = 0;
    await showPlayer(tester, store);
    await tester.pumpWidget(const SizedBox());
    store.source
        .complete(PlaybackSource.objectUrl('blob:late', () => releases++));
    await tester.pumpAndSettle();
    expect(releases, 1);
    expect(calls, isNot(contains('setSourceUrl')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('URL remains valid until player disposal completes',
      (tester) async {
    var releases = 0;
    await loadPlayer(tester, _Store(), onRelease: () => releases++);
    pendingDispose = Completer<void>();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
    expect(calls, contains('dispose'));
    expect(releases, 0);
    pendingDispose!.complete();
    await tester.pumpAndSettle();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
    expect(releases, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late playback rejection after removal is handled',
      (tester) async {
    var releases = 0;
    await loadPlayer(tester, _Store(), onRelease: () => releases++);
    pendingResume = Completer<void>();
    await tester.tap(find.byIcon(Icons.play_circle_filled));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    pendingResume!.completeError(
        PlatformException(code: 'AbortError', message: 'Media removed'));
    await tester.pumpAndSettle();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
    expect(releases, 1);
    expect(tester.takeException(), isNull);
  });
}
