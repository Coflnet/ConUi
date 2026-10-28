import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relationship_manager/models/event.dart';
import 'package:relationship_manager/services/dia_recording_detector.dart';
import 'package:relationship_manager/services/recording_file_store.dart';
import 'package:relationship_manager/services/transcription_client.dart';
import 'package:relationship_manager/services/wav.dart';

import '../support/fake_speech_detector.dart';

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

class _PcmDetector extends EndingDetector {
  bool _hasSpeech = false;
  @override
  Future<bool> speechEnded(Uint8List frame) async {
    _hasSpeech |= frame.any((byte) => byte != 0);
    return false;
  }

  @override
  bool get hasSpeech => _hasSpeech;
  @override
  void reset({bool continuing = false}) => _hasSpeech = false;
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

  test('streams exact six-second units and tail with stable analysis identity',
      () async {
    final pcm = Uint8List.fromList(
        List.generate(unit * 2 + 258, (index) => index % 251));
    final wav = WavHeader.wrap(pcm);
    final requests = <http.Request>[];
    final analysisIds = <String>{};
    for (final chunkSize in [7, 44, 65537, wav.length]) {
      requests.clear();
      final result = await detectRecordingTranscript(
          createSpeechDetector: () async => EndingDetector(minSpeechFrames: 1),
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
      analysisIds.add(identities.single!);
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
    expect(analysisIds, hasLength(1));
  });

  test('partial analysis retries keep IDs, sequence numbers and PCM hashes',
      () async {
    final pcm = Uint8List.fromList(
        List.generate(unit * 2 + 258, (index) => index % 251));
    final wav = WavHeader.wrap(pcm);
    final attempts = <List<http.Request>>[[], []];
    for (var attempt = 0; attempt < attempts.length; attempt++) {
      final analysis = detectRecordingTranscript(
          createSpeechDetector: () async => EndingDetector(minSpeechFrames: 1),
          file: file,
          store: _Store(wav, chunkSize: attempt == 0 ? 137 : 65537),
          client: client((request) async {
            attempts[attempt].add(request);
            if (attempt == 0 && attempts[attempt].length == 2) {
              throw http.ClientException('Interrupted');
            }
            return http.Response('{"text":"recognized"}', 200);
          }));
      if (attempt == 0) {
        await expectLater(analysis, throwsA(isA<TranscriptionException>()));
      } else {
        expect(await analysis, hasLength(3));
      }
    }
    expect(attempts.first, hasLength(2));
    for (var index = 0; index < attempts.first.length; index++) {
      final first = attempts.first[index];
      final retry = attempts.last[index];
      expect(retry.url.queryParameters['recordingId'],
          first.url.queryParameters['recordingId']);
      expect(retry.url.queryParameters['segment'], '$index');
      expect(sha256.convert(retry.bodyBytes).toString(),
          sha256.convert(first.bodyBytes).toString());
    }
    expect(file.transcriptSlices, isEmpty);
  });

  test('analysis identities distinguish file IDs and saved content hashes',
      () async {
    final ids = <String>{};
    for (final metadata in [
      file.toJson(),
      {...file.toJson(), 'id': 'other-recording'},
      {...file.toJson(), 'sha256': 'saved-content-hash'},
      {...file.toJson(), 'sha256': 'different-content-hash'},
    ]) {
      await detectRecordingTranscript(
          createSpeechDetector: () async => EndingDetector(minSpeechFrames: 1),
          file: AttachedFile.fromJson(metadata),
          store: _Store(WavHeader.wrap(Uint8List(unit))),
          client: client((request) async {
            ids.add(request.url.queryParameters['recordingId']!);
            return http.Response('{"text":"recognized"}', 200);
          }));
    }
    expect(ids, hasLength(4));
  });

  test('a complete six-second unit never sends an empty trailing request',
      () async {
    var calls = 0;
    final result = await detectRecordingTranscript(
        createSpeechDetector: () async => EndingDetector(minSpeechFrames: 1),
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
              createSpeechDetector: () async =>
                  EndingDetector(minSpeechFrames: 1),
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
            createSpeechDetector: () async =>
                EndingDetector(minSpeechFrames: 1),
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

  test('long guest and authenticated recordings retain all original offsets',
      () async {
    final pcm = Uint8List(61 * 32000);
    final wav = WavHeader.wrap(pcm);
    for (final token in [null, 'signed-in']) {
      var calls = 0, created = 0;
      final detector = EndingDetector(minSpeechFrames: 1);
      final slices = await detectRecordingTranscript(
          createSpeechDetector: () async {
            created++;
            return detector;
          },
          file: file,
          store: _Store(wav, chunkSize: 65537),
          client: TranscriptionClient(
              baseUrl: 'https://con.example',
              getToken: () => token,
              httpClient: MockClient((_) async {
                calls++;
                return http.Response('{"text":"recognized"}', 200);
              })));
      expect(calls, 11);
      expect(created, 1);
      expect(detector.disposed, isTrue);
      expect(slices.first.startByte, 0);
      expect(slices.last.endByte, pcm.length);
      expect(
          slices.fold<int>(
              0, (sum, slice) => sum + slice.endByte - slice.startByte),
          pcm.length);
      expect(wav, WavHeader.wrap(pcm));
    }
  });

  test('silence keeps empty original slices and speech upload identity',
      () async {
    final pcm = Uint8List(unit * 3)..fillRange(unit, unit * 2, 1);
    final requests = <http.Request>[];
    final detector = _PcmDetector();
    final slices = await detectRecordingTranscript(
        createSpeechDetector: () async => detector,
        file: file,
        store: _Store(WavHeader.wrap(pcm), chunkSize: 65537),
        client: client((request) async {
          requests.add(request);
          return http.Response('{"text":"speech"}', 200);
        }));
    expect(requests, hasLength(1));
    expect(requests.single.url.queryParameters['segment'], '1');
    expect(requests.single.bodyBytes,
        WavHeader.wrap(Uint8List.sublistView(pcm, unit, unit * 2)));
    expect(
        slices.map((slice) => (slice.startByte, slice.endByte, slice.text)), [
      (0, unit, ''),
      (unit, unit * 2, 'speech'),
      (unit * 2, unit * 3, ''),
    ]);
    expect(detector.disposed, isTrue);
  });

  test('unavailable or failed VAD never uploads unclassified audio', () async {
    final detector = EndingDetector(fail: true);
    for (final factory in [
      () async => detector,
      () async => throw StateError('Model unavailable'),
    ]) {
      await expectLater(
          detectRecordingTranscript(
              createSpeechDetector: factory,
              file: file,
              store: _Store(WavHeader.wrap(Uint8List(unit))),
              client: client((_) async => throw StateError('No upload'))),
          throwsA(isA<TranscriptionException>().having(
              (error) => error.slug, 'slug', 'speech_detection_unavailable')));
    }
    expect(detector.disposed, isTrue);
    expect(file.transcriptSlices, isEmpty);
  });

  test('cancellation after VAD initialization releases its detector', () async {
    var cancelled = false;
    final detector = EndingDetector();
    await expectLater(
        detectRecordingTranscript(
            createSpeechDetector: () async {
              cancelled = true;
              return detector;
            },
            isCancelled: () => cancelled,
            file: file,
            store: _Store(WavHeader.wrap(Uint8List(unit))),
            client: client((_) async => throw StateError('No upload'))),
        throwsStateError);
    expect(detector.disposed, isTrue);
  });

  test(
      'cancellation before or during recognition never returns partial results',
      () async {
    for (final cancelImmediately in [true, false]) {
      var cancelled = cancelImmediately, calls = 0;
      await expectLater(
          detectRecordingTranscript(
              createSpeechDetector: () async =>
                  EndingDetector(minSpeechFrames: 1),
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
