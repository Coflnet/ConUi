import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relationship_manager/services/transcription_client.dart';

void main() {
  group('transcribeSegment', () {
    test('sends the WAV bytes with auth header and returns the text', () async {
      http.Request? captured;
      final client = TranscriptionClient(
        baseUrl: 'https://api.example.com',
        getToken: () => 'tok-123',
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(jsonEncode({'text': 'hello world'}), 200);
        }),
      );

      final result =
          await client.transcribeSegment(Uint8List.fromList([1, 2, 3]));

      expect(result, 'hello world');
      expect(captured!.url.path, '/api/transcription/segment');
      expect(captured!.headers['Authorization'], 'Bearer tok-123');
      expect(captured!.headers['Content-Type'], 'audio/wav');
      expect(captured!.bodyBytes, [1, 2, 3]);
    });

    test('adds the language query parameter when given', () async {
      Uri? capturedUri;
      final client = TranscriptionClient(
        baseUrl: 'https://api.example.com',
        getToken: () => 'tok',
        httpClient: MockClient((request) async {
          capturedUri = request.url;
          return http.Response(jsonEncode({'text': ''}), 200);
        }),
      );

      await client.transcribeSegment(Uint8List(0), language: 'de');

      expect(capturedUri!.queryParameters['language'], 'de');
    });

    test(
        'sends bounded Unicode context in a header without changing audio or URL',
        () async {
      http.Request? captured;
      final client = TranscriptionClient(
          baseUrl: 'https://con.example',
          getToken: () => null,
          httpClient: MockClient((request) async {
            captured = request;
            return http.Response('{"text":"next"}', 200);
          }));
      final tail = List.filled(1024, '🙂').join();
      await client.transcribeSegment(Uint8List.fromList([1, 2, 3]),
          initialPrompt: 'Old context $tail  ');
      expect(
          utf8.decode(
              base64Decode(captured!.headers['X-Transcription-Prompt']!)),
          tail);
      expect(captured!.url.query, isEmpty);
      expect(captured!.bodyBytes, [1, 2, 3]);
    });

    test('omits blank context', () async {
      final client = TranscriptionClient(
          baseUrl: 'https://con.example',
          getToken: () => null,
          httpClient: MockClient((request) async {
            expect(
                request.headers.containsKey('X-Transcription-Prompt'), false);
            return http.Response('{"text":"next"}', 200);
          }));
      await client.transcribeSegment(Uint8List(0), initialPrompt: ' \n ');
    });

    test('sends anonymous recording identity without a bearer token', () async {
      http.Request? captured;
      final client = TranscriptionClient(
        baseUrl: 'https://api.example.com',
        getToken: () => null,
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response('{"text":"anonymous"}', 200);
        }),
      );
      expect(
          await client.transcribeSegment(Uint8List(0),
              recordingId: 'test-recording', segment: 2, language: 'de'),
          'anonymous');
      expect(captured!.headers.containsKey('Authorization'), isFalse);
      expect(captured!.url.queryParameters, {
        'recordingId': 'test-recording',
        'segment': '2',
        'language': 'de',
      });
    });

    test('throws offline without hitting the network when baseUrl is empty',
        () async {
      var called = false;
      final client = TranscriptionClient(
        baseUrl: '',
        getToken: () => 'tok',
        httpClient: MockClient((request) async {
          called = true;
          return http.Response('{}', 200);
        }),
      );

      await expectLater(
        () => client.transcribeSegment(Uint8List(0)),
        throwsA(isA<TranscriptionException>()
            .having((e) => e.kind, 'kind', TranscriptionErrorKind.offline)),
      );
      expect(called, isFalse);
    });

    test('classifies every documented status/slug', () async {
      Future<void> expectKind(
          int status, String slug, TranscriptionErrorKind kind) async {
        final client = TranscriptionClient(
          baseUrl: 'https://api.example.com',
          getToken: () => 'tok',
          httpClient: MockClient((request) async => http.Response(
              jsonEncode({'slug': slug, 'message': 'nope'}), status)),
        );
        await expectLater(
          () => client.transcribeSegment(Uint8List(0)),
          throwsA(isA<TranscriptionException>()
              .having((e) => e.kind, 'kind', kind)
              .having((e) => e.slug, 'slug', slug)),
        );
      }

      await expectKind(
          401, 'unauthorized', TranscriptionErrorKind.unauthorized);
      await expectKind(
          413, 'too_large', TranscriptionErrorKind.payloadTooLarge);
      await expectKind(
          415, 'bad_media', TranscriptionErrorKind.unsupportedMedia);
      await expectKind(429, 'rate_limited', TranscriptionErrorKind.rateLimited);
      await expectKind(502, 'transcription_failed',
          TranscriptionErrorKind.transcriptionFailed);
      await expectKind(
          429, 'anonymous_daily_limit', TranscriptionErrorKind.anonymousLimit);
      await expectKind(413, 'anonymous_recording_too_long',
          TranscriptionErrorKind.anonymousLimit);
      await expectKind(
          503, 'recording_quota_unavailable', TranscriptionErrorKind.other);
      await expectKind(503, 'transcription_not_configured',
          TranscriptionErrorKind.notConfigured);
    });

    test('a transport failure is reported as offline', () async {
      final client = TranscriptionClient(
        baseUrl: 'https://api.example.com',
        getToken: () => 'tok',
        httpClient: MockClient((request) async {
          throw const SocketExceptionStub();
        }),
      );

      await expectLater(
        () => client.transcribeSegment(Uint8List(0)),
        throwsA(isA<TranscriptionException>()
            .having((e) => e.kind, 'kind', TranscriptionErrorKind.offline)),
      );
    });
  });

  group('refreshUsage', () {
    test('reads cumulative speech allowance without authentication', () async {
      final client = TranscriptionClient(
        baseUrl: 'https://api.example.com',
        getToken: () => null,
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/transcription/status');
          expect(request.headers.containsKey('Authorization'), isFalse);
          return http.Response(
              '{"available":true,"usedSeconds":300,"remainingSeconds":0,"dailyLimitSeconds":300,"resetAt":"2050-01-01T00:00:00Z"}',
              200);
        }),
      );
      expect((await client.refreshUsage())!.remainingSeconds, 0);
    });

    test('network failure leaves anonymous allowance unknown', () async {
      final client = TranscriptionClient(
        baseUrl: 'https://api.example.com',
        getToken: () => null,
        httpClient: MockClient((request) async {
          throw const SocketExceptionStub();
        }),
      );
      expect(await client.refreshUsage(), isNull);
    });
  });

  group('isAvailable', () {
    test('usage cannot regress within a day or leak across account changes', () async {
      String? token;
      final replies = [
        {'usedSeconds': 240, 'remainingSeconds': 60, 'dailyLimitSeconds': 300,
          'resetAt': '2050-01-02T00:00:00Z'},
        {'usedSeconds': 181, 'remainingSeconds': 119, 'dailyLimitSeconds': 300,
          'resetAt': '2050-01-02T00:00:00Z'},
        {'usedSeconds': 0, 'remainingSeconds': 300, 'dailyLimitSeconds': 300,
          'resetAt': '2050-01-03T00:00:00Z'},
        {'usedSeconds': 250, 'remainingSeconds': 50, 'dailyLimitSeconds': 300,
          'resetAt': '2050-01-02T00:00:00Z'},
        {'usedSeconds': 30, 'remainingSeconds': 1170, 'dailyLimitSeconds': 1200,
          'resetAt': '2050-01-03T00:00:00Z'},
      ];
      var index = 0;
      final client = TranscriptionClient(baseUrl: 'https://api.example.com',
        getToken: () => token,
        httpClient: MockClient((request) async {
          expect(request.headers['Authorization'], token == null ? null : 'Bearer $token');
          return http.Response(jsonEncode(replies[index++]), 200);
        }));
      expect((await client.refreshUsage())!.usedSeconds, 240);
      expect((await client.refreshUsage())!.usedSeconds, 240);
      expect((await client.refreshUsage())!.usedSeconds, 0);
      expect((await client.refreshUsage())!.usedSeconds, 0);
      token = 'signed-in';
      expect(client.usage, isNull);
      final signed = (await client.refreshUsage())!;
      expect(signed.usedSeconds, 30);
      expect(signed.dailyLimitSeconds, 1200);
      expect(signed.remainingSeconds, 1170);
    });

    test('true when the backend reports available', () async {
      final client = TranscriptionClient(
        baseUrl: 'https://api.example.com',
        getToken: () => 'tok',
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/transcription/status');
          expect(request.headers['Authorization'], 'Bearer tok');
          return http.Response(jsonEncode({'available': true}), 200);
        }),
      );
      expect(await client.isAvailable(), isTrue);
    });

    test('false without a configured backend, without hitting the network',
        () async {
      var called = false;
      final client = TranscriptionClient(
        baseUrl: '',
        getToken: () => 'tok',
        httpClient: MockClient((request) async {
          called = true;
          return http.Response('{}', 200);
        }),
      );
      expect(await client.isAvailable(), isFalse);
      expect(called, isFalse);
    });

    test('checks anonymous availability without a bearer token', () async {
      final client = TranscriptionClient(
        baseUrl: 'https://api.example.com',
        getToken: () => null,
        httpClient: MockClient((request) async {
          expect(request.headers.containsKey('Authorization'), isFalse);
          return http.Response(jsonEncode({'available': true}), 200);
        }),
      );
      expect(await client.isAvailable(), isTrue);
    });

    test('false on any network error', () async {
      final client = TranscriptionClient(
        baseUrl: 'https://api.example.com',
        getToken: () => 'tok',
        httpClient: MockClient((request) async {
          throw const SocketExceptionStub();
        }),
      );
      expect(await client.isAvailable(), isFalse);
    });
  });
}

/// Minimal stand-in for a real socket failure, so tests don't depend on
/// dart:io's SocketException constructor shape.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
  @override
  String toString() => 'SocketExceptionStub';
}
