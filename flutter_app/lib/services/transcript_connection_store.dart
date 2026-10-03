import '../models/event.dart';
import '../models/person.dart';
import '../relationships/relationship_type.dart';
import 'database_service.dart';

/// Persists reviewed, resolved transcript information after its story is saved.
Future<void> saveTranscriptInformation(
  DatabaseService db,
  Event event,
  List<
          ({
            Person person1,
            Person person2,
            RelationshipType type,
            String sourceText
          })>
      connections,
  List<({Person person, String value, String sourceText, bool isCompany})>
      facts,
) async {
  final savedEvent = await db.getEvent(event.id);
  if (savedEvent == null || savedEvent.isDeleted) {
    throw StateError('Save the story before its transcript information.');
  }
  final people = await db.getPersons();
  final personIds = people.map((person) => person.id).toSet();
  final existing = await db.getConnections();
  final selectedIds = <String>{};
  for (final candidate in connections) {
    if (candidate.person1.id == candidate.person2.id ||
        !personIds.contains(candidate.person1.id) ||
        !personIds.contains(candidate.person2.id)) {
      continue;
    }
    Connection? match;
    for (final connection in existing) {
      if (isDuplicateConnection(
        existing: [
          (
            person1Id: connection.person1Id,
            person2Id: connection.person2Id,
            relationshipType: connection.relationshipType
          ),
        ],
        person1Id: candidate.person1.id,
        person2Id: candidate.person2.id,
        type: candidate.type,
      )) {
        match = connection;
        break;
      }
    }
    if (match == null) {
      match = Connection(
        person1Id: candidate.person1.id,
        person2Id: candidate.person2.id,
        relationshipType: candidate.type.name,
        originEventId: event.id,
        sourceEventIds: [event.id],
        isInferred: true,
        description: candidate.sourceText,
        startDate: savedEvent.dateTime,
      );
      await db.saveConnection(match);
      existing.add(match);
    } else if (!match.sourceEventIds.contains(event.id)) {
      final updated = match.copyWith(
        sourceEventIds: [...match.sourceEventIds, event.id],
      );
      await db.saveConnection(updated);
      existing[existing.indexOf(match)] = updated;
      match = updated;
    }
    selectedIds.add(match.id);
  }
  for (final connection in existing) {
    if (selectedIds.contains(connection.id) ||
        !connection.sourceEventIds.contains(event.id)) {
      continue;
    }
    final sources = connection.sourceEventIds
        .where((source) => source != event.id)
        .toList();
    await db.saveConnection(connection.copyWith(
      sourceEventIds: sources,
      isDeleted: connection.isInferred && sources.isEmpty,
      originEventId: connection.isInferred &&
              connection.originEventId == event.id &&
              sources.isNotEmpty
          ? sources.first
          : connection.originEventId,
    ));
  }

  for (final person in people) {
    final selected = facts.where((fact) => fact.person.id == person.id);
    final clauses = selected
        .map((fact) => fact.sourceText.trim())
        .where((clause) => clause.isNotEmpty)
        .toSet()
        .join('\n');
    var company = person.company;
    if (company == null || company.trim().isEmpty) {
      for (final fact in selected) {
        if (fact.isCompany && fact.value.trim().isNotEmpty) {
          company = fact.value.trim();
          break;
        }
      }
    }
    if ((person.storyFacts[event.id] ?? '') == clauses &&
        person.company == company) {
      continue;
    }
    final storyFacts = {...person.storyFacts}..remove(event.id);
    if (clauses.isNotEmpty) storyFacts[event.id] = clauses;
    await db
        .savePerson(person.copyWith(storyFacts: storyFacts, company: company));
  }
}
