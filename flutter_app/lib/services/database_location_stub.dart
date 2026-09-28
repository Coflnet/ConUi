// Fallback used when neither dart:io nor dart:html is available. Should
// never actually be reached by this app's supported platforms (Android,
// iOS, desktop, web); it exists so the conditional import in
// database_location.dart always has somewhere to resolve to. Same pattern
// as recording_file_store_stub.dart.
import 'database_location.dart';

Future<DatabaseLocation> resolveDatabaseLocation(
  String fileName, {
  String? supportDirectoryOverride,
}) =>
    throw UnsupportedError(
        'No database location implementation is available on this platform.');
