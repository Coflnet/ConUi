import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../models/models.dart';
import 'person_mentions.dart';
import 'recording_file_store.dart';
import 'transcript_connections.dart';

enum TrainingSampleError {
  network,
  tooLarge,
  unsupported,
  rateLimited,
  unauthorized,
  unavailable,
  conflict,
  missingAudio,
  invalid,
  other,
}

class TrainingSampleException implements Exception {
  final TrainingSampleError kind;
  const TrainingSampleException(this.kind);
}

/// Explicit upload whitelist: never serialize a Person or Event into a report.
class TrainingSamplePerson {
  final String name;
  final String? company;
  final List<String> facts;

  const TrainingSamplePerson(
      {required this.name, this.company, this.facts = const []});

  Map<String, dynamic> toJson() => {
        'name': name,
        if (company != null) 'company': company,
        'facts': facts,
      };
}

class TrainingSampleConnection {
  final String person1Name;
  final String person2Name;
  final String type;

  const TrainingSampleConnection(this.person1Name, this.person2Name, this.type);

  Map<String, dynamic> toJson() => {
        'person1Name': person1Name,
        'person2Name': person2Name,
        'type': type,
      };
}

class TrainingSampleSnapshot {
  final String transcript;
  final List<TrainingSamplePerson> people;
  final List<TrainingSampleConnection> connections;

  const TrainingSampleSnapshot(
      {required this.transcript,
      this.people = const [],
      this.connections = const []});

  factory TrainingSampleSnapshot.fromStory(
      Event event, List<Person> people, List<Connection> connections) {
    final storyConnections = connections
        .where((c) =>
            !c.isDeleted &&
            (c.originEventId == event.id ||
                c.sourceEventIds.contains(event.id)))
        .toList();
    final ids = {
      ...event.participantIds,
      ...storyConnections.expand((c) => [c.person1Id, c.person2Id])
    };
    final storyPeople = people
        .where((p) =>
            !p.isDeleted &&
            (ids.contains(p.id) || p.storyFacts.containsKey(event.id)))
        .toList();
    final names = {for (final p in storyPeople) p.id: p.name};
    final extractedFacts =
        extractTranscriptConnections(event.description ?? '', storyPeople)
            .facts;
    return TrainingSampleSnapshot(
      transcript: event.description ?? '',
      people: storyPeople.map((p) {
        final facts = (p.storyFacts[event.id] ?? '')
            .split('\n')
            .where((fact) => fact.trim().isNotEmpty)
            .toList();
        // Global company has no source provenance. Only include an employer
        // linked to this person's saved facts for this specific story.
        final companies = extractedFacts.where((f) =>
            facts.contains(f.sourceText.trim()) &&
            f.isCompany &&
            extractPersonMentions(f.personName, [p]).any(
                (mention) => mention.matches.any((match) => match.id == p.id)));
        return TrainingSamplePerson(
            name: p.name,
            facts: facts,
            company: companies.isEmpty ? null : companies.first.value);
      }).toList(),
      connections: storyConnections
          .where((c) =>
              names.containsKey(c.person1Id) && names.containsKey(c.person2Id))
          .map((c) => TrainingSampleConnection(
              names[c.person1Id]!, names[c.person2Id]!, c.relationshipType))
          .toList(),
    );
  }
}

class TrainingSampleClient {
  static const maxAudioBytes = 10 * 1024 * 1024;
  static const maxMetadataBytes = 64 * 1024;
  final String baseUrl;
  final String? Function() getToken;
  final http.Client _http;
  final bool _ownsClient;

  TrainingSampleClient(
      {required this.baseUrl, required this.getToken, http.Client? httpClient})
      : _http = httpClient ?? http.Client(),
        _ownsClient = httpClient == null;

  void close() {
    if (_ownsClient) _http.close();
  }

  Future<String> submit(
      {required String sampleId,
      required bool consent,
      required TrainingSampleSnapshot snapshot,
      required String correction,
      String? language,
      RecordingFileStore? store,
      String? recordingId}) async {
    if (!consent ||
        (recordingId == null && snapshot.transcript.trim().isEmpty)) {
      throw const TrainingSampleException(TrainingSampleError.invalid);
    }
    final metadata = jsonEncode({
      'sampleId': sampleId,
      'consent': true,
      'transcript': snapshot.transcript,
      'correction': correction,
      if (language != null) 'language': language,
      'people': snapshot.people.map((p) => p.toJson()).toList(),
      'connections': snapshot.connections.map((c) => c.toJson()).toList(),
    });
    if (snapshot.transcript.length > 32000 ||
        correction.length > 4000 ||
        snapshot.people.length > 50 ||
        snapshot.connections.length > 100 ||
        utf8.encode(metadata).length > maxMetadataBytes) {
      throw const TrainingSampleException(TrainingSampleError.tooLarge);
    }
    try {
      final request = http.MultipartRequest(
          'POST', Uri.parse('$baseUrl/api/training-samples'));
      final token = getToken();
      if (token != null) request.headers['Authorization'] = 'Bearer $token';
      request.fields['metadata'] = metadata;
      if (recordingId != null) {
        if (store == null || !await store.exists(recordingId)) {
          throw const TrainingSampleException(TrainingSampleError.missingAudio);
        }
        final size = await store.size(recordingId);
        if (size > maxAudioBytes) {
          throw const TrainingSampleException(TrainingSampleError.tooLarge);
        }
        request.files.add(http.MultipartFile(
            'audio', _boundedAudio(store, recordingId, size), size,
            filename: 'sample.wav', contentType: MediaType('audio', 'wav')));
      }
      final response = await _http
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 90));
      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data['id'] == sampleId) return sampleId;
        throw const TrainingSampleException(TrainingSampleError.other);
      }
      throw TrainingSampleException(switch (response.statusCode) {
        401 => TrainingSampleError.unauthorized,
        413 => TrainingSampleError.tooLarge,
        415 => TrainingSampleError.unsupported,
        429 => TrainingSampleError.rateLimited,
        503 => TrainingSampleError.unavailable,
        409 => TrainingSampleError.conflict,
        400 => TrainingSampleError.invalid,
        _ => TrainingSampleError.other,
      });
    } on TrainingSampleException {
      rethrow;
    } on FormatException {
      throw const TrainingSampleException(TrainingSampleError.other);
    } catch (_) {
      throw const TrainingSampleException(TrainingSampleError.network);
    }
  }

  Stream<List<int>> _boundedAudio(
      RecordingFileStore store, String id, int size) async* {
    var sent = 0;
    await for (final chunk in store.openReadStream(id)) {
      sent += chunk.length;
      if (sent > size || sent > maxAudioBytes) {
        throw const TrainingSampleException(TrainingSampleError.tooLarge);
      }
      yield chunk;
    }
    if (sent != size) {
      throw const TrainingSampleException(TrainingSampleError.missingAudio);
    }
  }
}
