import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Why a transcription request failed, so callers (RecorderController) can
/// decide whether to retry and, for the UI, why live transcription isn't
/// working right now.
enum TranscriptionErrorKind {
  /// No backend is configured, or the request never reached it.
  offline,

  /// The backend rejected authentication (401).
  unauthorized,

  /// Anonymous daily or recording-duration allowance exhausted.
  anonymousLimit,

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
///   bytes as the body, optional `Authorization: Bearer <token>` and
///   `Content-Type: audio/wav`, with language/recordingId/segment query fields;
///   success is
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
  /// Anonymous recordings carry stable recording/segment identities so
  /// concurrent chunks and retries consume one recording allowance.
  /// Throws [TranscriptionException] on offline or backend-reported errors.
  Future<String> transcribeSegment(Uint8List wavBytes, {
    String? language,
    String? recordingId,
    int? segment,
  }) async {
    if (!isConfigured) {
      throw const TranscriptionException(
          TranscriptionErrorKind.offline, 'No backend address is configured.');
    }
    final token = getToken();
    final uri = Uri.parse('$baseUrl/api/transcription/segment').replace(
      queryParameters: {
        if (language != null && language.isNotEmpty) 'language': language,
        if (recordingId != null) 'recordingId': recordingId,
        if (segment != null) 'segment': '$segment',
      },
    );

    final http.Response response;
    try {
      response = await _http.post(
        uri,
        headers: {
          if (token != null) 'Authorization': 'Bearer $token',
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
    final token = getToken();
    try {
      final response = await _http.get(
        Uri.parse('$baseUrl/api/transcription/status'),
        headers: {if (token != null) 'Authorization': 'Bearer $token'},
      );
      if (response.statusCode != 200) return false;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data['available'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Null means quota status could not be checked; offline capture stays usable.
  Future<int?> remainingAnonymousRecordings() async {
    if (!isConfigured) return null;
    try {
      final response = await _http.get(
        Uri.parse('$baseUrl/api/transcription/status'),
      ).timeout(const Duration(seconds: 3));
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data['remainingRecordings'] as int?;
    } catch (_) {
      return null;
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

    if (slug == 'anonymous_daily_limit' || slug == 'anonymous_recording_too_long') {
      return TranscriptionException(TranscriptionErrorKind.anonymousLimit, message,
          statusCode: response.statusCode, slug: slug);
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
        kind = slug == 'recording_quota_unavailable'
            ? TranscriptionErrorKind.other
            : TranscriptionErrorKind.notConfigured;
        break;
      default:
        kind = TranscriptionErrorKind.other;
    }
    return TranscriptionException(kind, message,
        statusCode: response.statusCode, slug: slug);
  }
}
