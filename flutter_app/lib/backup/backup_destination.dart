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

  /// True when [description] is a path inside this app's OWN private
  /// storage rather than somewhere the user actually chose - i.e.
  /// Android/iOS (see backup_destination_native.dart's doc comment for
  /// why [BackupDestinationProvider] has nowhere better to put it there on
  /// its own). That storage is deleted if the app is uninstalled and isn't
  /// reachable with a file manager, so a backup that lives only there
  /// protects against nothing - the UI must treat this as a TEMPORARY
  /// holding spot and offer the user a real destination via
  /// [BackupExportOffer] (see backup_export.dart) rather than reporting it
  /// as done. Always false on desktop (the user already chose a real path)
  /// and web (already downloaded via the browser).
  final bool isPrivateAppStorage;

  const BackupSaveLocation(
      {required this.description, required this.isFilePath, this.isPrivateAppStorage = false});
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
///   file_picker's `saveFile` (the only platforms file_picker implements it
///   on), then streams straight to a temp file next to it and renames on
///   commit.
/// - Android/iOS: file_picker's `saveFile` needs the whole file as bytes in
///   memory on these platforms even in current versions (see the final
///   report) - unusable for a multi-hundred-MB recording - so [commit]
///   here only finishes writing to this app's own documents directory
///   under `backups/` (again via a temp-file-then-rename) and reports
///   [BackupSaveLocation.isPrivateAppStorage]; getting the file out to a
///   real, user-chosen location from there is [BackupExportOffer]'s job
///   (see backup_export.dart), not this class's.
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
