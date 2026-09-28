// Test helper for opening an in-memory SQLite database through
// sqflite_common_ffi, so unit and widget tests never touch the real
// filesystem or IndexedDB backends.
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:relationship_manager/services/database_service.dart';

/// Distinguishes each call's database name from every other's, see
/// [createTestDatabaseService] for why this has to vary per call.
int _testDatabaseCounter = 0;

/// Creates a [DatabaseService] backed by a fresh, isolated in-memory
/// database. Each call returns a service with its own database, so tests
/// don't leak state into one another.
///
/// This does *not* open sqflite_common_ffi's special [inMemoryDatabasePath]
/// (`:memory:`) constant directly: every call passing that exact literal
/// path ends up sharing the very same underlying connection - the ffi
/// factory caches opened databases keyed by their path string, and
/// `:memory:` is the same string on every call, so a second call would
/// silently reopen the first call's database instead of getting its own.
/// Passing a SQLite URI that names a distinct, private in-memory database
/// instead gives every call its own cache key - and so its own database -
/// while still never touching the filesystem (`mode=memory`) or being
/// reachable from any other connection even if the name were ever reused
/// (`cache=private`).
DatabaseService createTestDatabaseService() {
  sqfliteFfiInit();
  final name = 'test_db_${_testDatabaseCounter++}';
  return DatabaseService(
    factory: databaseFactoryFfi,
    path: 'file:$name?mode=memory&cache=private',
  );
}
