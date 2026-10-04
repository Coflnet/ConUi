import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/services/training_sample_client.dart';

import '../support/training_sample_fakes.dart';

const sampleId = '765db1c0-79bb-4fbd-9b8f-a7dcf208c743';
const snapshot =
    TrainingSampleSnapshot(transcript: 'Typed note. Spoken story.');

void main() {
  late CaptureTrainingHttp httpClient;
  late TrainingSampleClient client;
  late ReportRecordingStore store;
  setUp(() {
    httpClient = CaptureTrainingHttp();
    client = TrainingSampleClient(
        baseUrl: 'https://example.invalid',
        getToken: () => null,
        httpClient: httpClient);
    store = ReportRecordingStore();
  });
  Future<String> submit(
          {bool consent = true,
          TrainingSampleSnapshot data = snapshot,
          String correction = '',
          bool audio = true}) =>
      client.submit(
          sampleId: sampleId,
          consent: consent,
          snapshot: data,
          correction: correction,
          language: 'en',
          store: audio ? store : null,
          recordingId: audio ? 'private-owner-recording-id' : null);

  test('no consent never reads audio or sends a request', () async {
    await expectLater(
        submit(consent: false),
        throwsA(isA<TrainingSampleException>()
            .having((e) => e.kind, 'kind', TrainingSampleError.invalid)));
    expect(httpClient.calls, 0);
    expect(store.sizeReads, 0);
    expect(store.streamReads, 0);
  });

  test(
      'story snapshot whitelists only this story and source-scoped facts/company',
      () {
    final james = Person(
        id: 'james-id',
        name: 'James',
        company: 'Private employer',
        phoneNumber: 'private-phone',
        email: 'private-email',
        notes: 'private-notes',
        customAttributes: {
          'secret': 'private-attribute'
        },
        storyFacts: {
          'story': 'James works at Google\nJames has a new car',
          'another': 'private-fact'
        });
    final paul =
        Person(id: 'paul-id', name: 'Paul', company: 'Unrelated company');
    final unrelated = Person(id: 'unrelated-id', name: 'Unrelated person');
    final event = Event(
        id: 'story',
        title: 'Private story title',
        description: 'James works at Google\nJames has a new car',
        dateTime: DateTime(2020),
        participantIds: ['james-id']);
    final data = TrainingSampleSnapshot.fromStory(event, [
      james,
      paul,
      unrelated
    ], [
      Connection(
          person1Id: james.id,
          person2Id: paul.id,
          relationshipType: 'sibling',
          sourceEventIds: ['story']),
      Connection(
          person1Id: paul.id,
          person2Id: unrelated.id,
          relationshipType: 'colleague',
          originEventId: 'another'),
    ]);
    expect(data.transcript, 'James works at Google\nJames has a new car');
    expect(data.people.map((p) => p.name), ['James', 'Paul']);
    expect(data.people.first.toJson(), {
      'name': 'James',
      'company': 'Google',
      'facts': ['James works at Google', 'James has a new car']
    });
    expect(data.people.last.toJson(), {'name': 'Paul', 'facts': []});
    expect(data.connections.single.toJson(),
        {'person1Name': 'James', 'person2Name': 'Paul', 'type': 'sibling'});
    final serialized = jsonEncode(data.people.map((p) => p.toJson()).toList());
    for (final forbidden in [
      'private-',
      'Unrelated',
      'james-id',
      'paul-id',
      'email',
      'phone',
      'notes',
      'customAttributes'
    ]) {
      expect(serialized, isNot(contains(forbidden)));
    }
  });

  test(
      'relative employer is resolved from this story, preserving its saved fact scope',
      () {
    final event = Event(
        id: 'story',
        title: 'Story',
        dateTime: DateTime(2020),
        description:
            'James Smith is the brother of Paul Miller, who works at Google and is a colleague of Dana White. James Smith got a new car.',
        participantIds: ['james', 'paul', 'dana']);
    final people = [
      Person(
          id: 'james',
          name: 'James Smith',
          company: 'Private employer',
          storyFacts: {'story': 'James Smith got a new car'}),
      Person(
          id: 'paul',
          name: 'Paul Miller',
          company: 'Private employer',
          storyFacts: {'story': 'who works at Google'}),
      Person(id: 'dana', name: 'Dana White'),
    ];
    final result = TrainingSampleSnapshot.fromStory(event, people, []);
    expect(result.people[1].company, 'Google');
    expect(result.people.first.company, isNull);
    // A removed employer suggestion must stay excluded even if text mentions it.
    people[1].storyFacts.clear();
    expect(
        TrainingSampleSnapshot.fromStory(event, people, []).people[1].company,
        isNull);
  });

  test(
      'audio-only failed-transcription sample works; empty metadata-only fails',
      () async {
    expect(await submit(data: const TrainingSampleSnapshot(transcript: '')),
        sampleId);
    expect(httpClient.request!.files.single.filename, 'sample.wav');
    await expectLater(
        submit(
            data: const TrainingSampleSnapshot(transcript: ''), audio: false),
        throwsA(isA<TrainingSampleException>()
            .having((e) => e.kind, 'kind', TrainingSampleError.invalid)));
    expect(httpClient.calls, 1);
  });

  test('unknown captured language is omitted from uploaded metadata', () async {
    await client.submit(
        sampleId: sampleId, consent: true, snapshot: snapshot, correction: '');
    final metadata = jsonDecode(httpClient.request!.fields['metadata']!) as Map;
    expect(metadata.containsKey('language'), false);
  });

  test('guest multipart streams original WAV and replaces owner filename/id',
      () async {
    expect(await submit(correction: 'Actually siblings.'), sampleId);
    final request = httpClient.request!;
    expect(request.url.path, '/api/training-samples');
    expect(request.headers, isNot(contains('Authorization')));
    final metadata = jsonDecode(request.fields['metadata']!) as Map;
    expect(metadata, {
      'sampleId': sampleId,
      'consent': true,
      'transcript': snapshot.transcript,
      'correction': 'Actually siblings.',
      'language': 'en',
      'people': [],
      'connections': []
    });
    expect(request.files.single.filename, 'sample.wav');
    expect(request.files.single.contentType.toString(), 'audio/wav');
    expect(request.files.single.length, 48);
    expect(store.sizeReads, 1);
    expect(store.streamReads, 1);
    // The submitted body contains the original contiguous bytes unmodified.
    final body = latin1.decode(httpClient.body!);
    expect(body, contains(latin1.decode(store.chunks.single)));
    expect(body, isNot(contains('private-owner-recording-id')));
  });

  test(
      'metadata-only report works without local audio and reads current bearer',
      () async {
    store.present = false;
    var token = 'first-token';
    client = TrainingSampleClient(
        baseUrl: 'https://example.invalid',
        getToken: () => token,
        httpClient: httpClient);
    await submit(audio: false);
    expect(httpClient.request!.headers['Authorization'], 'Bearer first-token');
    token = 'fresh-token';
    await submit(audio: false);
    expect(httpClient.request!.headers['Authorization'], 'Bearer fresh-token');
    expect(httpClient.request!.files, isEmpty);
    expect(store.sizeReads, 0);
    expect(store.streamReads, 0);
  });

  test('missing and oversized originals are rejected before stream/send',
      () async {
    store.present = false;
    await expectLater(
        submit(),
        throwsA(isA<TrainingSampleException>()
            .having((e) => e.kind, 'kind', TrainingSampleError.missingAudio)));
    store.present = true;
    store.sizeBytes = TrainingSampleClient.maxAudioBytes + 1;
    await expectLater(
        submit(),
        throwsA(isA<TrainingSampleException>()
            .having((e) => e.kind, 'kind', TrainingSampleError.tooLarge)));
    expect(httpClient.calls, 0);
    expect(store.streamReads, 0);
  });

  test('stream cannot send bytes beyond the checked size or accept truncation',
      () async {
    store.sizeBytes = 47;
    await expectLater(
        submit(),
        throwsA(isA<TrainingSampleException>()
            .having((e) => e.kind, 'kind', TrainingSampleError.tooLarge)));
    store.sizeBytes = 49;
    await expectLater(
        submit(),
        throwsA(isA<TrainingSampleException>()
            .having((e) => e.kind, 'kind', TrainingSampleError.missingAudio)));
  });

  test('metadata limits reject before reading audio or posting', () async {
    for (final data in [
      TrainingSampleSnapshot(transcript: 'x' * 32001),
      TrainingSampleSnapshot(transcript: '漢' * 32000),
      TrainingSampleSnapshot(
          transcript: '',
          people: List.generate(
              51, (_) => const TrainingSamplePerson(name: 'Person'))),
      TrainingSampleSnapshot(
          transcript: '',
          connections: List.generate(
              101, (_) => const TrainingSampleConnection('A', 'B', 'friend'))),
    ]) {
      await expectLater(
          submit(data: data),
          throwsA(isA<TrainingSampleException>()
              .having((e) => e.kind, 'kind', TrainingSampleError.tooLarge)));
    }
    await expectLater(
        submit(correction: 'x' * 4001),
        throwsA(isA<TrainingSampleException>()
            .having((e) => e.kind, 'kind', TrainingSampleError.tooLarge)));
    expect(httpClient.calls, 0);
    expect(store.sizeReads, 0);
  });

  for (final (status, kind) in [
    (401, TrainingSampleError.unauthorized),
    (413, TrainingSampleError.tooLarge),
    (415, TrainingSampleError.unsupported),
    (429, TrainingSampleError.rateLimited),
    (503, TrainingSampleError.unavailable),
    (409, TrainingSampleError.conflict),
    (400, TrainingSampleError.invalid),
    (500, TrainingSampleError.other),
  ]) {
    test('HTTP $status maps safely without leaking server body', () async {
      httpClient.status = status;
      httpClient.responseBody =
          '{"slug":"failure","message":"private-token-or-url"}';
      await expectLater(
          submit(audio: false),
          throwsA(isA<TrainingSampleException>()
              .having((e) => e.kind, 'kind', kind)));
    });
  }
  test('network failures and malformed receipts are sanitized', () async {
    httpClient.failure = Exception('https://private-url?token=secret');
    await expectLater(
        submit(audio: false),
        throwsA(isA<TrainingSampleException>()
            .having((e) => e.kind, 'kind', TrainingSampleError.network)));
    httpClient.failure = null;
    httpClient.responseBody = '{"id":"private-token"}';
    await expectLater(
        submit(audio: false),
        throwsA(isA<TrainingSampleException>()
            .having((e) => e.kind, 'kind', TrainingSampleError.other)));
  });
}
