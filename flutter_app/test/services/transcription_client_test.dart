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

    test('throws unauthorized without hitting the network when signed out',
        () async {
      var called = false;
      final client = TranscriptionClient(
        baseUrl: 'https://api.example.com',
        getToken: () => null,
        httpClient: MockClient((request) async {
          called = true;
          return http.Response('{}', 200);
        }),
      );

      await expectLater(
        () => client.transcribeSegment(Uint8List(0)),
        throwsA(isA<TranscriptionException>().having(
            (e) => e.kind, 'kind', TranscriptionErrorKind.unauthorized)),
      );
      expect(called, isFalse);
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

      await expectKind(401, 'unauthorized', TranscriptionErrorKind.unauthorized);
      await expectKind(413, 'too_large', TranscriptionErrorKind.payloadTooLarge);
      await expectKind(415, 'bad_media', TranscriptionErrorKind.unsupportedMedia);
      await expectKind(429, 'rate_limited', TranscriptionErrorKind.rateLimited);
      await expectKind(
          502, 'transcription_failed', TranscriptionErrorKind.transcriptionFailed);
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

  group('isAvailable', () {
    test('true when the backend reports available', () async {
      final client = TranscriptionClient(
        baseUrl: 'https://api.example.com',
        getToken: () => 'tok',
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/transcription/status');
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
