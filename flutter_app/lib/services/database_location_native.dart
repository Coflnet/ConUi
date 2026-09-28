import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'database_location.dart';

/// Native (Android/iOS/desktop) database location.
///
/// The database always lives under the app's application-support
/// directory - never a path relative to the process's current working
/// directory, which on Android isn't writable at all (that's what made
/// the app crash at start with `SqfliteFfiException ... code 14`) and on
/// desktop depends on wherever the app happened to be launched from.
///
/// Android and iOS use the real `sqflite` plugin (a platform channel to
/// the OS's own SQLite), which is the well-supported, tested path on
/// those platforms. Desktop keeps `sqflite_common_ffi`, which needs a
/// system `libsqlite3` available to `dlopen` - reliably true on desktop,
/// not on Android.
Future<DatabaseLocation> resolveDatabaseLocation(
  String fileName, {
  String? supportDirectoryOverride,
}) async {
  final useNativePlugin = Platform.isAndroid || Platform.isIOS;

  final supportDirPath = supportDirectoryOverride ??
      (await getApplicationSupportDirectory()).path;
  final supportDir = Directory(supportDirPath);
  if (!await supportDir.exists()) {
    await supportDir.create(recursive: true);
  }

  final newPath = p.join(supportDirPath, fileName);
  await _migrateOldDatabaseIfPresent(fileName, newPath);

  return DatabaseLocation(newPath, useNativePlugin);
}

/// Earlier builds opened the database at [fileName] resolved against
/// whatever the process's current working directory happened to be - on
/// desktop that could be a real, writable file with real user data. If
/// that old file still exists and nothing has been written at [newPath]
/// yet, move it across so a desktop user's existing data isn't silently
/// orphaned by this fix. If a database already exists at [newPath] (a
/// fresh install, or a device that already migrated), leave the old file
/// alone rather than risk overwriting real data.
Future<void> _migrateOldDatabaseIfPresent(
    String fileName, String newPath) async {
  if (await File(newPath).exists()) return;

  final oldFile = File(fileName);
  if (!await oldFile.exists()) return;

  try {
    await oldFile.rename(newPath);
  } on FileSystemException {
    // rename() fails when the old and new paths are on different
    // filesystems/devices (e.g. the old CWD-relative path happened to be
    // on a different mount than the app support directory) - fall back to
    // a copy-then-delete, which works across filesystems.
    await oldFile.copy(newPath);
    await oldFile.delete();
  }
}
