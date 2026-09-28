import 'database_location_stub.dart'
    if (dart.library.io) 'database_location_native.dart'
    if (dart.library.html) 'database_location_web.dart' as impl;

/// Where the app database should live, and which plugin should open it.
///
/// Resolved per-platform via conditional import - the same pattern
/// [RecordingFileStore] uses - so `dart:io` is never referenced from code
/// that gets compiled for web.
class DatabaseLocation {
  /// Absolute filesystem path to open the database at. On web this is just
  /// the logical database name sqflite_common_ffi_web/idb_shim use as a
  /// key, not a real filesystem path.
  final String path;

  /// True when the real native `sqflite` plugin (platform channel to the
  /// OS's own SQLite) should be used instead of `sqflite_common_ffi`.
  /// `sqflite_common_ffi` opens SQLite by `dlopen`-ing a shared library and
  /// is the right choice on desktop, where the OS provides a system
  /// `libsqlite3`; Android does not reliably expose one to arbitrary apps,
  /// and the native plugin is the well-supported, tested path there (and
  /// on iOS).
  final bool useNativePlugin;

  const DatabaseLocation(this.path, this.useNativePlugin);
}

Future<DatabaseLocation> resolveDatabaseLocation(
  String fileName, {
  String? supportDirectoryOverride,
}) =>
    impl.resolveDatabaseLocation(
      fileName,
      supportDirectoryOverride: supportDirectoryOverride,
    );
