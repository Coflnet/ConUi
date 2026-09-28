import 'backup_export_stub.dart'
    if (dart.library.io) 'backup_export_native.dart'
    if (dart.library.html) 'backup_export_web.dart' as impl;

/// Gets a backup that [BackupDestinationProvider] could only leave in this
/// app's own private storage (see [BackupSaveLocation.isPrivateAppStorage])
/// out to somewhere that actually survives an uninstall, through dialogs
/// the operating system itself owns - never by this app inventing its own
/// upload/cloud integration.
///
/// - Android/iOS: [needsExport] is true.
///   - [saveAs] opens the Storage Access Framework's document-creation
///     dialog ("Save to...") so the user can put the file on a cloud
///     drive, an SD card, or anywhere else their system exposes.
///   - [share] opens the system share sheet ("Share...") so the file can be
///     sent to another app, another device, or a computer.
///   Both take the backup by its file PATH and hand it to the underlying
///   plugin as such - never reading it into memory here - so a
///   several-hundred-MB backup is exported exactly as cheaply as it was
///   written.
/// - Desktop/web: [needsExport] is false and the other methods are never
///   called - [BackupDestinationProvider] already put the file somewhere
///   the user chose (desktop) or that their browser manages (web).
abstract class BackupExportOffer {
  bool get needsExport;

  /// Opens the SAF "Save to..." dialog for the file at [sourceFilePath].
  /// Returns a human-readable description of where it ended up, or null if
  /// the user cancelled the dialog.
  Future<String?> saveAs({required String sourceFilePath, required String suggestedFileName});

  /// Opens the system share sheet for the file at [sourceFilePath]. Returns
  /// true if the user picked a target app, false if they dismissed the
  /// sheet without doing so. (Best-effort on Android: the platform doesn't
  /// always distinguish "shared successfully" from "picked an app that
  /// then failed" - see backup_export_native.dart.)
  Future<bool> share({required String sourceFilePath, required String suggestedFileName});

  /// Deletes the temporary app-private copy at [path] once it's no longer
  /// needed (successfully exported elsewhere, or superseded by a new
  /// backup attempt) - see [BackupSaveLocation.isPrivateAppStorage]. Safe
  /// to call even if [path] no longer exists.
  Future<void> deleteTemporaryCopy(String path);
}

BackupExportOffer createBackupExportOffer() => impl.createBackupExportOffer();
