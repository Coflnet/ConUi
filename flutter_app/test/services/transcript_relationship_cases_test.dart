import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/models/person.dart';
import 'package:relationship_manager/services/person_mentions.dart';
import 'package:relationship_manager/services/transcript_connections.dart';

void main() {
  final cases = (jsonDecode(
    File('test/fixtures/transcript_relationship_cases.json').readAsStringSync(),
  ) as List<dynamic>)
      .cast<Map<String, dynamic>>();

  for (final item in cases) {
    test('${item['id']}: ${item['family']} (${item['language']})', () {
      final text = item['text'] as String;
      final people = [
        for (final person in (item['people'] as List<dynamic>? ?? []))
          Person(
            id: person['id'] as String,
            name: person['name'] as String,
            aliases: (person['aliases'] as List<dynamic>? ?? []).cast<String>(),
          ),
      ];
      // Unique existing names and aliases compare by identity. Ambiguous names
      // remain surface names: choosing their IDs belongs to controller review.
      String endpoint(String name) {
        final mentions = extractPersonMentions(name, people);
        if (mentions.length == 1 &&
            mentions.single.matches.length == 1 &&
            normalizedPersonName(mentions.single.name) ==
                normalizedPersonName(name)) {
          return 'id:${mentions.single.matches.single.id}';
        }
        return name;
      }

      final result = extractTranscriptConnections(text, people);
      expect(
        [
          for (final connection in result.connections)
            {
              'from': endpoint(connection.person1Name),
              'type': connection.type.name,
              'to': endpoint(connection.person2Name),
            },
        ],
        unorderedEquals(item['expected'] as List<dynamic>),
        reason: '$text\n${item['note'] ?? ''}',
      );
      for (final connection in result.connections) {
        expect(connection.sourceText.trim(), isNotEmpty, reason: text);
        expect(text, contains(connection.sourceText),
            reason: 'Evidence must be a literal span of the transcript.');
      }
    });
  }
}
