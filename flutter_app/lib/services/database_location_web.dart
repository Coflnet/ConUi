// Web implementation: sqflite_common_ffi_web/idb_shim store the database in
// IndexedDB keyed by a logical name, not a filesystem path, so there is
// nothing to resolve to a real directory and no native plugin to pick.
import 'database_location.dart';

Future<DatabaseLocation> resolveDatabaseLocation(
  String fileName, {
  String? supportDirectoryOverride,
}) async =>
    DatabaseLocation(fileName, false);
