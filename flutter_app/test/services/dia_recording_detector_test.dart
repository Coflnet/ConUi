import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relationship_manager/models/event.dart';
import 'package:relationship_manager/services/dia_recording_detector.dart';
import 'package:relationship_manager/services/recording_file_store.dart';
import 'package:relationship_manager/services/transcription_client.dart';
import 'package:relationship_manager/services/wav.dart';

class _Store implements RecordingFileStore {
  final Uint8List bytes;
  final int chunkSize;
  final int? declaredSize;
  _Store(this.bytes, {this.chunkSize = 137, this.declaredSize});

  @override
  Future<int> size(String id) async => declaredSize ?? bytes.length;

  @override
  Stream<List<int>> openReadStream(String id) async* {
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      yield Uint8List.sublistView(
          bytes, offset, (offset + chunkSize).clamp(0, bytes.length));
    }
  }

  // Whole reads, writes, and microphone access are never part of detection.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected operation: ${invocation.memberName}');
}

void main() {
  const unit = 6 * 32000;
  final file = AttachedFile(
      id: 'original-recording',
      fileName: 'original.wav',
      filePath: 'original-recording',
      mimeType: 'audio/wav',
      size: 0,
      kind: AttachedFile.kindRecording);

  TranscriptionClient client(
          Future<http.Response> Function(http.Request) send) =>
      TranscriptionClient(
          baseUrl: 'https://con.example',
          getToken: () => null,
          httpClient: MockClient(send));

  test('streams exact six-second units and tail with fresh stable identity',
      () async {
    final pcm = Uint8List.fromList(
        List.generate(unit * 2 + 258, (index) => index % 251));
    final wav = WavHeader.wrap(pcm);
    final requests = <http.Request>[];
    final analysisIds = <String>{};
    for (final chunkSize in [7, 44, 65537, wav.length]) {
      requests.clear();
      final result = await detectRecordingTranscript(
          file: file,
          store: _Store(wav, chunkSize: chunkSize),
          language: 'de',
          client: client((request) async {
            requests.add(request);
            return http.Response(
                jsonEncode({
                  'text':
                      requests.length == 2 ? ' ' : ' text ${requests.length} '
                }),
                200);
          }));
      expect(requests, hasLength(3));
      final identities =
          requests.map((r) => r.url.queryParameters['recordingId']).toSet();
      expect(identities, hasLength(1));
      expect(
          identities.single, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f-]{27}$')));
      expect(identities.single, isNot(file.id));
      expect(analysisIds.add(identities.single!), isTrue);
      for (var i = 0; i < requests.length; i++) {
        expect(requests[i].url.queryParameters['segment'], '$i');
        expect(requests[i].url.queryParameters['language'], 'de');
        expect(requests[i].headers.containsKey('Authorization'), isFalse);
        expect(
            requests[i].bodyBytes,
            WavHeader.wrap(Uint8List.sublistView(
                pcm, i * unit, ((i + 1) * unit).clamp(0, pcm.length))));
      }
      expect(result.map((s) => (s.startByte, s.endByte, s.text)), [
        (0, unit, 'text 1'),
        (unit, unit * 2, ''),
        (unit * 2, pcm.length, 'text 3'),
      ]);
      expect(wav, WavHeader.wrap(pcm));
      expect(file.transcriptSlices, isEmpty);
    }
  });

  test('a complete six-second unit never sends an empty trailing request',
      () async {
    var calls = 0;
    final result = await detectRecordingTranscript(
        file: file,
        store: _Store(WavHeader.wrap(Uint8List(unit))),
        client: client((_) async {
          calls++;
          return http.Response('{"text":"complete"}', 200);
        }));
    expect(calls, 1);
    expect(result.single.endByte, unit);
  });

  test('validates complete canonical WAV before making any request', () async {
    final valid = WavHeader.wrap(Uint8List(100));
    final invalid = Uint8List.fromList(valid)..[24] = 0;
    final short = Uint8List.sublistView(valid, 0, valid.length - 2);
    for (final store in [
      _Store(Uint8List(10)),
      _Store(WavHeader.wrap(Uint8List(0))),
      _Store(WavHeader.wrap(Uint8List(3))),
      _Store(invalid),
      _Store(short),
      _Store(short, declaredSize: valid.length),
      _Store(valid, declaredSize: valid.length - 2),
    ]) {
      await expectLater(
          detectRecordingTranscript(
              file: file,
              store: store,
              client: client((_) async => throw StateError('No requests'))),
          throwsFormatException);
    }
  });

  test('failures propagate without returning partial analysis or retrying',
      () async {
    var calls = 0;
    await expectLater(
        detectRecordingTranscript(
            file: file,
            store: _Store(WavHeader.wrap(Uint8List(unit * 3))),
            client: client((_) async {
              calls++;
              return calls == 1
                  ? http.Response('{"text":"first"}', 200)
                  : http.Response('{"slug":"anonymous_daily_limit"}', 429);
            })),
        throwsA(isA<TranscriptionException>().having(
            (e) => e.kind, 'kind', TranscriptionErrorKind.anonymousLimit)));
    expect(calls, 2);
    expect(file.transcriptSlices, isEmpty);
  });

  test(
      'anonymous long recordings fail before ASR; signed-in analysis continues',
      () async {
    final wav = WavHeader.wrap(Uint8List(61 * 32000));
    for (final token in [null, 'signed-in']) {
      var calls = 0;
      final analysis = detectRecordingTranscript(
          file: file,
          store: _Store(wav, chunkSize: 65537),
          client: TranscriptionClient(
              baseUrl: 'https://con.example',
              getToken: () => token,
              httpClient: MockClient((_) async {
                calls++;
                return http.Response('{"text":"recognized"}', 200);
              })));
      if (token == null) {
        await expectLater(
            analysis,
            throwsA(isA<TranscriptionException>()
                .having((e) => e.kind, 'kind',
                    TranscriptionErrorKind.anonymousLimit)
                .having(
                    (e) => e.slug, 'slug', 'anonymous_recording_too_long')));
        expect(calls, 0);
      } else {
        final slices = await analysis;
        expect(calls, 11);
        expect(slices.last.endByte, 61 * 32000);
      }
    }
  });

  test(
      'cancellation before or during recognition never returns partial results',
      () async {
    for (final cancelImmediately in [true, false]) {
      var cancelled = cancelImmediately, calls = 0;
      await expectLater(
          detectRecordingTranscript(
              file: file,
              store: _Store(WavHeader.wrap(Uint8List(unit * 2))),
              isCancelled: () => cancelled,
              client: client((_) async {
                calls++;
                cancelled = true;
                return http.Response('{"text":"first"}', 200);
              })),
          throwsStateError);
      expect(calls, cancelImmediately ? 0 : 1);
      expect(file.transcriptSlices, isEmpty);
    }
  });
}
