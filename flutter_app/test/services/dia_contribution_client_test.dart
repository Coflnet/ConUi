import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relationship_manager/services/dia_contribution_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

const policy = DiaContributionPolicy(
  version: 'current-policy',
  information: 'Information',
  terms: 'Terms',
  privacyUrl: 'https://coflnet.com/de/privacy/',
  trainingTitle: 'Training',
  trainingDescription: 'Coflnet speech recognition only',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('fetches current training terms without Con authentication', () async {
    final client =
        DiaContributionClient(httpClient: MockClient((request) async {
      expect(request.url.toString(),
          'https://tab.coflnet.com/api/dialect/consents/notice');
      expect(request.headers.containsKey('authorization'), isFalse);
      return http.Response(
          jsonEncode({
            'version': policy.version,
            'information': policy.information,
            'terms': policy.terms,
            'privacyUrl': policy.privacyUrl,
            'purposes': [
              {'value': 2, 'title': 'Public', 'description': 'Publish'},
              {'value': 4, 'title': 'Training', 'description': 'Coflnet only'},
            ],
          }),
          200);
    }));
    final result = await client.fetchPolicy();
    expect(result.version, policy.version);
    expect(result.terms, policy.terms);
    expect(result.information, policy.information);
    expect(result.privacyUrl, policy.privacyUrl);
    expect(result.trainingTitle, 'Training');
    expect(result.trainingDescription, 'Coflnet only');
  });

  test('stores anonymous training grant before upload and returns references',
      () async {
    final requests = <http.Request>[];
    final client =
        DiaContributionClient(httpClient: MockClient((request) async {
      requests.add(request);
      final prefs = await SharedPreferences.getInstance();
      final key = prefs.getString(DiaContributionClient.deviceKeyPreference);
      expect(key, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(request.headers['X-Contribution-Key'], key);
      expect(request.headers.containsKey('authorization'), isFalse);
      if (request.url.path.endsWith('/consents')) {
        expect(jsonDecode(request.body), {
          'email': null,
          'purposes': 4,
          'version': policy.version,
          'acceptTerms': true,
        });
        return http.Response(
            '{"id":"grant-1","contributorAlias":"device@anonymous.invalid","purposes":4}',
            200);
      }
      expect(prefs.getStringList(DiaContributionClient.receiptsPreference),
          hasLength(1));
      expect(jsonDecode(request.body), {
        'base64Audio': 'AQID',
        'uploaderEmail': 'device@anonymous.invalid',
        'transcription': 'Corrected sentence.',
        'contributionConsentId': 'grant-1',
        'zipCode': '10115',
        'country': 'DE',
      });
      return http.Response('{"id":"recording-1","audioId":"audio"}', 200);
    }));
    final result = await client.submit(
        wavBytes: Uint8List.fromList([1, 2, 3]),
        correction: ' Corrected sentence. ',
        policy: policy,
        consent: true,
        zipCode: ' 10115 ',
        country: ' de ');
    expect(result.id, 'recording-1');
    expect(result.consentId, 'grant-1');
    final prefs = await SharedPreferences.getInstance();
    expect(
        jsonDecode(prefs
            .getStringList(DiaContributionClient.receiptsPreference)!
            .single)['recordingId'],
        'recording-1');
    expect(requests.map((request) => request.url.path),
        ['/api/dialect/consents', '/api/dialect/upload']);
  });

  test('refuses unconsented, empty or oversized samples before any request',
      () async {
    final client = DiaContributionClient(httpClient: MockClient((_) async {
      fail('Invalid input must not leave the device');
    }));
    for (final input in [
      (false, 'text', Uint8List(1)),
      (true, ' ', Uint8List(1)),
      (true, 'text', Uint8List(0)),
      (true, 'text', Uint8List(DiaContributionClient.maxWavBytes + 1)),
    ]) {
      await expectLater(
          client.submit(
              wavBytes: input.$3,
              correction: input.$2,
              policy: policy,
              consent: input.$1),
          throwsArgumentError);
    }
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });

  test('maximum twenty-second clip fits the public request buffer', () async {
    final client =
        DiaContributionClient(httpClient: MockClient((request) async {
      if (request.url.path.endsWith('/consents')) {
        return http.Response(
            '{"id":"grant","contributorAlias":"device@dia.invalid"}', 200);
      }
      expect(request.bodyBytes.length, lessThan(1024 * 1024));
      final body = jsonDecode(request.body) as Map;
      expect(base64Decode(body['base64Audio'] as String),
          hasLength(20 * 32000 + 44));
      return http.Response('{"id":"recording"}', 200);
    }));
    expect(
        (await client.submit(
                wavBytes: Uint8List(DiaContributionClient.maxWavBytes),
                correction: List.filled(4000, '𐀀').join(),
                policy: policy,
                consent: true))
            .id,
        'recording');
  });

  test('does not upload when consent creation fails or omits its alias',
      () async {
    for (final response in [
      http.Response('outdated policy', 409),
      http.Response('{"id":"grant"}', 200),
    ]) {
      var calls = 0;
      final client = DiaContributionClient(httpClient: MockClient((_) async {
        calls++;
        return response;
      }));
      await expectLater(
          client.submit(
              wavBytes: Uint8List(1),
              correction: 'text',
              policy: policy,
              consent: true),
          throwsA(isA<DiaContributionException>()));
      expect(calls, 1);
    }
  });

  test('retains device proof and consent receipt on failed upload', () async {
    SharedPreferences.setMockInitialValues({
      DiaContributionClient.deviceKeyPreference: 'existing-device-key',
    });
    final client =
        DiaContributionClient(httpClient: MockClient((request) async {
      expect(request.headers['X-Contribution-Key'], 'existing-device-key');
      if (request.url.path.endsWith('/consents')) {
        return http.Response(
            '{"id":"grant-2","contributorAlias":"anonymous@dia.invalid"}', 200);
      }
      final body = jsonDecode(request.body) as Map;
      expect(body.containsKey('zipCode'), isFalse);
      expect(body.containsKey('country'), isFalse);
      return http.Response('private backend details', 503);
    }));
    await expectLater(
        client.submit(
            wavBytes: Uint8List(1),
            correction: 'text',
            policy: policy,
            consent: true),
        throwsA(isA<DiaContributionException>()
            .having((error) => error.statusCode, 'statusCode', 503)));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(DiaContributionClient.deviceKeyPreference),
        'existing-device-key');
    expect(
        jsonDecode(prefs
            .getStringList(DiaContributionClient.receiptsPreference)!
            .single)['id'],
        'grant-2');
  });

  test('policy failures never fall back to legacy unconsented uploading',
      () async {
    for (final response in [
      http.Response('missing endpoint', 404),
      http.Response('{}', 200),
    ]) {
      final client =
          DiaContributionClient(httpClient: MockClient((_) async => response));
      await expectLater(
          client.fetchPolicy(), throwsA(isA<DiaContributionException>()));
    }
  });
}
