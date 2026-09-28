import 'package:archive/archive.dart';

import 'backup_destination_stub.dart'
    if (dart.library.io) 'backup_destination_native.dart'
    if (dart.library.html) 'backup_destination_web.dart' as impl;

/// Where a just-written backup archive ended up, in whatever terms make
/// sense for the platform: a filesystem path on native, or just "it was
/// downloaded" on web (browsers don't expose where a download landed).
class BackupSaveLocation {
  final String description;
  final bool isFilePath;
  const BackupSaveLocation({required this.description, required this.isFilePath});
}

/// One place to write a backup to: an [output] stream the writer streams
/// into; then, in order:
///  1. [finish] - closes [output] so the bytes written so far can be read
///     back (but doesn't commit them anywhere final yet).
///  2. [openForVerification] - an [InputStream] over exactly those bytes,
///     for BackupRestorer.verify() to check before anyone is told the
///     backup succeeded.
///  3. [commit] (only if verification passed) - makes the file the finished
///     backup (a rename into place on native, a browser download on web).
/// If anything goes wrong (or the caller cancels) before [commit], [abort]
/// must run instead and leave no partial file behind.
abstract class BackupWriteTarget {
  OutputStream get output;
  Future<void> finish();
  Future<InputStream> openForVerification();
  Future<BackupSaveLocation> commit();
  Future<void> abort();
}

/// Chooses and prepares a [BackupWriteTarget] for the current platform:
/// - Desktop (Linux/macOS/Windows): asks the user where to save via
///   file_picker's `saveFile` (the only platforms this installed file_picker
///   version supports it on), then streams straight to a temp file next to
///   it and renames on commit.
/// - Android/iOS: file_picker's `saveFile` isn't implemented on this
///   version for these platforms (see the final report), so the backup is
///   written to this app's own documents directory under `backups/`,
///   again via a temp-file-then-rename.
/// - Web: streaming isn't available, so the archive is built into memory
///   (see backup_writer.dart's memory notes) and [commit] triggers a
///   browser download of the finished bytes.
abstract class BackupDestinationProvider {
  /// Returns null if the user cancelled choosing a location (desktop save
  /// dialog) - callers should treat that exactly like a cancelled backup.
  Future<BackupWriteTarget?> prepareTarget(String suggestedFileName);
}

BackupDestinationProvider createBackupDestinationProvider() =>
    impl.createBackupDestinationProvider();
