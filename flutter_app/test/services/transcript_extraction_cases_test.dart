import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/services/transcript_connections.dart';

void main() {
  final cases = jsonDecode(
    File('test/fixtures/transcript_extraction_cases.json').readAsStringSync(),
  ) as List<dynamic>;
  for (final item in cases.cast<Map<String, dynamic>>()) {
    test('${item['id']}: ${item['category']}', () {
      final result = extractTranscriptConnections(item['text'] as String, []);
      final actual = {
        'connections': [
          for (final connection in result.connections)
            {
              'from': connection.person1Name,
              'type': connection.type.name,
              'to': connection.person2Name,
              'source': connection.sourceText,
            },
        ],
        'facts': [
          for (final fact in result.facts)
            {
              'person': fact.personName,
              'value': fact.value,
              'company': fact.isCompany,
              'source': fact.sourceText,
            },
        ],
      };
      expect(actual, item['expected'], reason: item['text'] as String);
    });
  }
}
