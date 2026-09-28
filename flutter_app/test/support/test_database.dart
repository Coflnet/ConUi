// Test helper for opening an in-memory SQLite database through
// sqflite_common_ffi, so unit and widget tests never touch the real
// filesystem or IndexedDB backends.
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:relationship_manager/services/database_service.dart';

/// Creates a [DatabaseService] backed by a fresh, isolated in-memory
/// database. Each call returns a service with its own database, so tests
/// don't leak state into one another.
DatabaseService createTestDatabaseService() {
  sqfliteFfiInit();
  return DatabaseService(
    factory: databaseFactoryFfi,
    path: inMemoryDatabasePath,
  );
}
