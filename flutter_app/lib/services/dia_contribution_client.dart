import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class DiaContributionPolicy {
  final String version, information, terms, privacyUrl;
  final String trainingTitle, trainingDescription;

  const DiaContributionPolicy({
    required this.version,
    required this.information,
    required this.terms,
    required this.privacyUrl,
    required this.trainingTitle,
    required this.trainingDescription,
  });
}

class DiaContributionReceipt {
  final String id, consentId;
  const DiaContributionReceipt({required this.id, required this.consentId});
}

class DiaContributionException implements Exception {
  final int? statusCode;
  const DiaContributionException([this.statusCode]);
}

/// Dia uses its own anonymous device proof; never send Con credentials here.
class DiaContributionClient {
  static const maxClipSeconds = 20;
  // Base64 plus the corrected text must fit Dia's public 1 MiB request limit.
  static const maxWavBytes = maxClipSeconds * 32000 + 44;
  static const deviceKeyPreference = 'dia_contribution_device_key';
  static const receiptsPreference = 'dia_contribution_receipts';
  final http.Client _http;
  final String _baseUrl;

  DiaContributionClient({
    http.Client? httpClient,
    String baseUrl = 'https://tab.coflnet.com',
  })  : _http = httpClient ?? http.Client(),
        _baseUrl = baseUrl.replaceFirst(RegExp(r'/$'), '');

  Future<Map<String, dynamic>> _request(String path,
      {Map<String, dynamic>? body, String? deviceKey}) async {
    final uri = Uri.parse('$_baseUrl/api/dialect/$path');
    final headers = {
      'Content-Type': 'application/json',
      if (deviceKey != null) 'X-Contribution-Key': deviceKey,
    };
    try {
      final response = await (body == null
              ? _http.get(uri, headers: headers)
              : _http.post(uri, headers: headers, body: jsonEncode(body)))
          .timeout(const Duration(seconds: 60));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw DiaContributionException(response.statusCode);
      }
      return jsonDecode(utf8.decode(response.bodyBytes))
          as Map<String, dynamic>;
    } on DiaContributionException {
      rethrow;
    } catch (_) {
      throw const DiaContributionException();
    }
  }

  Future<DiaContributionPolicy> fetchPolicy() async {
    final notice = await _request('consents/notice');
    try {
      final training = (notice['purposes'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((purpose) => purpose['value'] == 4);
      return DiaContributionPolicy(
        version: notice['version'] as String,
        information: notice['information'] as String,
        terms: notice['terms'] as String,
        privacyUrl: notice['privacyUrl'] as String,
        trainingTitle: training['title'] as String,
        trainingDescription: training['description'] as String,
      );
    } catch (_) {
      throw const DiaContributionException();
    }
  }

  Future<DiaContributionReceipt> submit({
    required Uint8List wavBytes,
    required String correction,
    required DiaContributionPolicy policy,
    required bool consent,
    String? zipCode,
    String? country,
  }) async {
    if (!consent ||
        correction.trim().isEmpty ||
        wavBytes.isEmpty ||
        wavBytes.length > maxWavBytes ||
        policy.version.isEmpty) {
      throw ArgumentError(
          'Explicit consent, corrected text and audio required');
    }
    final prefs = await SharedPreferences.getInstance();
    var key = prefs.getString(deviceKeyPreference);
    if (key == null) {
      final random = Random.secure();
      key = List.generate(
              32, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
          .join();
      if (!await prefs.setString(deviceKeyPreference, key)) {
        throw const DiaContributionException();
      }
    }
    final grant = await _request('consents', deviceKey: key, body: {
      'email': null,
      'purposes': 4,
      'version': policy.version,
      'acceptTerms': true,
    });
    final consentId = grant['id'];
    final alias = grant['contributorAlias'];
    if (consentId is! String ||
        consentId.isEmpty ||
        alias is! String ||
        alias.isEmpty) {
      throw const DiaContributionException();
    }
    // Keep the receipt even if uploading fails, so it remains withdrawable.
    final receipts = prefs.getStringList(receiptsPreference) ?? [];
    receipts.add(jsonEncode(grant));
    if (!await prefs.setStringList(receiptsPreference, receipts)) {
      throw const DiaContributionException();
    }
    final uploaded = await _request('upload', deviceKey: key, body: {
      'base64Audio': base64Encode(wavBytes),
      'uploaderEmail': alias,
      'transcription': correction.trim(),
      'contributionConsentId': consentId,
      if (zipCode != null && zipCode.trim().isNotEmpty)
        'zipCode': zipCode.trim(),
      if (country != null && country.trim().isNotEmpty)
        'country': country.trim().toUpperCase(),
    });
    final id = uploaded['id'];
    if (id is! String || id.isEmpty) throw const DiaContributionException();
    // The server has accepted the clip. Local storage must not invite a
    // duplicate upload by turning that success into a retryable failure.
    try {
      receipts[receipts.length - 1] = jsonEncode({...grant, 'recordingId': id});
      await prefs.setStringList(receiptsPreference, receipts);
    } catch (_) {
      // The returned reference remains available to the caller.
    }
    return DiaContributionReceipt(id: id, consentId: consentId);
  }

  void dispose() => _http.close();
}
