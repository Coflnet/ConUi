import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Why a transcription request failed, so callers (RecorderController) can
/// decide whether to retry and, for the UI, why live transcription isn't
/// working right now.
enum TranscriptionErrorKind {
  /// No backend is configured, or the request never reached it.
  offline,

  /// No token available, or the backend rejected it (401).
  unauthorized,

  /// The segment was too large (413).
  payloadTooLarge,

  /// The backend didn't accept the audio format (415).
  unsupportedMedia,

  /// Too many requests (429).
  rateLimited,

  /// The backend explicitly reported a transcription failure (502, slug
  /// `transcription_failed`).
  transcriptionFailed,

  /// The backend has transcription turned off (503, slug
  /// `transcription_not_configured`).
  notConfigured,

  /// Anything else.
  other,
}

class TranscriptionException implements Exception {
  final TranscriptionErrorKind kind;
  final String message;
  final int? statusCode;
  final String? slug;

  const TranscriptionException(
    this.kind,
    this.message, {
    this.statusCode,
    this.slug,
  });

  @override
  String toString() => 'TranscriptionException($kind, $statusCode): $message';
}

/// Client for the backend's transcription contract:
/// - `POST {baseUrl}/api/transcription/segment` with the segment's WAV
///   bytes as the body, `Authorization: Bearer <token>` and
///   `Content-Type: audio/wav`, optional `?language=`; success is
///   `{"text": "..."}`; failure is `{"slug": "...", "message": "..."}`.
/// - `GET {baseUrl}/api/transcription/status` -> `{"available": bool}`.
class TranscriptionClient {
  /// Empty means no backend is configured (see AuthService.baseUrl).
  final String baseUrl;

  /// Returns the current auth token, or null when signed out.
  final String? Function() getToken;

  final http.Client _http;

  TranscriptionClient({
    required this.baseUrl,
    required this.getToken,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  bool get isConfigured => baseUrl.isNotEmpty;

  /// Sends one WAV-wrapped audio segment and returns its transcribed text.
  /// Throws [TranscriptionException] on any failure - offline, not signed
  /// in, or a backend-reported error.
  Future<String> transcribeSegment(Uint8List wavBytes, {String? language}) async {
    if (!isConfigured) {
      throw const TranscriptionException(
          TranscriptionErrorKind.offline, 'No backend address is configured.');
    }
    final token = getToken();
    if (token == null) {
      throw const TranscriptionException(TranscriptionErrorKind.unauthorized,
          'Sign in to use live transcription.');
    }

    var uri = Uri.parse('$baseUrl/api/transcription/segment');
    if (language != null && language.isNotEmpty) {
      uri = uri.replace(queryParameters: {'language': language});
    }

    final http.Response response;
    try {
      response = await _http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'audio/wav',
        },
        body: wavBytes,
      );
    } catch (e) {
      throw TranscriptionException(TranscriptionErrorKind.offline,
          'Could not reach the transcription service: $e');
    }

    if (response.statusCode == 200) {
      try {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data['text'] as String? ?? '';
      } catch (e) {
        throw TranscriptionException(TranscriptionErrorKind.other,
            'Unexpected transcription response: $e');
      }
    }

    throw _errorFor(response);
  }

  /// Whether the backend currently has transcription available at all.
  /// Never throws - any failure (offline, not configured, ...) is reported
  /// as unavailable.
  Future<bool> isAvailable() async {
    if (!isConfigured) return false;
    try {
      final response =
          await _http.get(Uri.parse('$baseUrl/api/transcription/status'));
      if (response.statusCode != 200) return false;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data['available'] == true;
    } catch (_) {
      return false;
    }
  }

  TranscriptionException _errorFor(http.Response response) {
    String? slug;
    var message = 'Transcription request failed (${response.statusCode}).';
    try {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      slug = data['slug'] as String?;
      message = (data['message'] as String?) ?? message;
    } catch (_) {
      // Non-JSON error body; keep the generic message.
    }

    final TranscriptionErrorKind kind;
    switch (response.statusCode) {
      case 401:
        kind = TranscriptionErrorKind.unauthorized;
        break;
      case 413:
        kind = TranscriptionErrorKind.payloadTooLarge;
        break;
      case 415:
        kind = TranscriptionErrorKind.unsupportedMedia;
        break;
      case 429:
        kind = TranscriptionErrorKind.rateLimited;
        break;
      case 502:
        kind = TranscriptionErrorKind.transcriptionFailed;
        break;
      case 503:
        kind = TranscriptionErrorKind.notConfigured;
        break;
      default:
        kind = TranscriptionErrorKind.other;
    }
    return TranscriptionException(kind, message,
        statusCode: response.statusCode, slug: slug);
  }
}
