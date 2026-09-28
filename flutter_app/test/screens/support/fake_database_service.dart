import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/services/database_service.dart';

/// An in-memory stand-in for [DatabaseService] used by widget tests, so tests never
/// touch the real sqflite file the production service opens (`relationship_manager.db`
/// at a fixed relative path - not safe to open from a test process). Every method the
/// screens under test call is overridden to read/write plain in-memory maps instead of
/// ever reaching the base class's `database` getter; [DatabaseService.deletePerson] and
/// [DatabaseService.deleteEvent] are left un-overridden since the base class
/// implements them purely in terms of the other overridden methods (Dart's normal
/// virtual dispatch means they end up using this class's in-memory versions too).
class FakeDatabaseService extends DatabaseService {
  final Map<String, Person> persons = {};
  final Map<String, Connection> connections = {};
  final Map<String, Event> events = {};

  @override
  bool get isInitialized => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<List<Person>> getPersons({bool includeDeleted = false}) async =>
      persons.values.where((p) => includeDeleted || !p.isDeleted).toList();

  @override
  Future<Person?> getPerson(String id) async => persons[id];

  @override
  Future<void> savePerson(Person person, {bool recordPendingChange = true}) async {
    persons[person.id] = person;
    notifyListeners();
  }

  @override
  Future<List<Connection>> getConnections({bool includeDeleted = false}) async =>
      connections.values.toList();

  @override
  Future<Connection?> getConnection(String id) async => connections[id];

  @override
  Future<List<Connection>> getConnectionsForPerson(String personId,
          {bool includeDeleted = false}) async =>
      connections.values
          .where((c) => c.person1Id == personId || c.person2Id == personId)
          .toList();

  @override
  Future<List<Connection>> getConnectionsForEvent(String eventId) async =>
      connections.values.where((c) => c.originEventId == eventId).toList();

  @override
  Future<void> saveConnection(Connection connection,
      {bool recordPendingChange = true}) async {
    connections[connection.id] = connection;
    notifyListeners();
  }

  @override
  Future<void> deleteConnection(String id) async {
    connections.remove(id);
    notifyListeners();
  }

  @override
  Future<List<Event>> getEvents({String? monthKey, bool includeDeleted = false}) async =>
      events.values.where((e) => monthKey == null || e.monthKey == monthKey).toList();

  @override
  Future<Event?> getEvent(String id) async => events[id];

  @override
  Future<void> saveEvent(Event event, {bool recordPendingChange = true}) async {
    events[event.id] = event;
    notifyListeners();
  }
}
