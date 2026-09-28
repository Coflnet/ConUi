/// Errors a restore can raise while parsing/validating an archive, before
/// (or instead of) touching any local data. Each has a plain-English
/// [message] safe to show directly to the user; callers that want a
/// friendlier, localized wording can still switch on the type.
sealed class BackupRestoreException implements Exception {
  final String message;
  const BackupRestoreException(this.message);

  @override
  String toString() => message;
}

/// The file isn't a valid zip archive, or is truncated/corrupt enough that
/// it can't be parsed at all.
class BackupArchiveCorruptException extends BackupRestoreException {
  final Object cause;
  BackupArchiveCorruptException(this.cause)
      : super('This file is not a valid backup archive '
            '(it may be corrupt or incomplete): $cause');
}

/// manifest.json declares a formatVersion this code doesn't know how to
/// read.
class UnsupportedBackupVersionException extends BackupRestoreException {
  final int foundVersion;
  UnsupportedBackupVersionException(this.foundVersion)
      : super('This backup was made with a newer or unrecognized format '
            '(version $foundVersion). Update the app and try again.');
}

/// The archive is missing a required entry, or that entry doesn't parse as
/// the JSON it's supposed to be.
class BackupFormatException extends BackupRestoreException {
  BackupFormatException(super.message);
}

/// An entry (or the archive as a whole) exceeds the sane size/count limits
/// in [BackupSafetyLimits].
class BackupTooLargeException extends BackupRestoreException {
  BackupTooLargeException(super.message);
}

/// Raised by a long-running backup/restore when the caller's cancellation
/// check reports the user asked to cancel. Callers catch this to clean up
/// (delete a partial temp file, discard an in-memory buffer) and must never
/// let a cancelled run leave a file that looks finished.
class BackupCancelledException implements Exception {
  const BackupCancelledException();

  @override
  String toString() => 'Backup cancelled';
}
