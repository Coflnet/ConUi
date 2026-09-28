/// Every user-facing string for the backup/restore feature (settings
/// screen tiles, the create/restore flows, and their result screens), kept
/// in one place so a later localisation pass has a single file to work
/// from and so none of it is buried inside backup_service.dart/
/// backup_writer.dart/backup_restorer.dart's logic.
class BackupStrings {
  BackupStrings._();

  // ---- Settings screen tiles ----
  static const String sectionTitle = 'Backup';
  static const String createTitle = 'Create backup';
  static const String createSubtitleIdle =
      'Save your stories, people, places and recordings to a file';
  static String createSubtitleLastBackup(String when) => 'Last backup: $when';
  static const String createSubtitleNever = 'No backup has been made yet';
  static const String restoreTitle = 'Restore from backup';
  static const String restoreSubtitle = 'Merge a backup file back in';
  static const String recordingsSpaceTitle = 'Recordings on this device';

  /// Shown under "Create backup" when recordings exist that were made
  /// after the last successful backup.
  static String newRecordingsReminder(int count) => count == 1
      ? '1 recording was made since your last backup'
      : '$count recordings were made since your last backup';

  // ---- Create backup flow ----
  static const String previewTitle = 'This backup will include';
  static String previewCounts(Map<String, int> counts) {
    final parts = <String>[
      if ((counts['persons'] ?? 0) > 0) '${counts['persons']} people',
      if ((counts['connections'] ?? 0) > 0) '${counts['connections']} connections',
      if ((counts['places'] ?? 0) > 0) '${counts['places']} places',
      if ((counts['events'] ?? 0) > 0) '${counts['events']} stories',
      if ((counts['objects'] ?? 0) > 0) '${counts['objects']} objects',
    ];
    return parts.isEmpty ? 'Nothing yet - the backup will be empty' : parts.join(', ');
  }

  static String recordingsSummary(int count, int totalBytes) =>
      '$count recording${count == 1 ? '' : 's'} ($totalBytes bytes)';

  static String missingAudioWarning(int count) => count == 1
      ? '1 story\'s recording is not on this device and will NOT be '
          'included in this backup.'
      : '$count stories\' recordings are not on this device and will NOT '
          'be included in this backup.';

  static const String webSizeWarningTitle = 'Large backup';
  static String webSizeWarningBody(String sizeText, String limitText) =>
      'This backup is about $sizeText. Building it in the browser needs to '
      'hold the whole file in memory, and backups over about $limitText can '
      'make the browser tab slow or crash on some devices. Continue anyway?';

  static const String creatingTitle = 'Creating backup…';
  static const String cancel = 'Cancel';
  static const String verifying = 'Verifying…';

  static const String createSuccessTitle = 'Backup created';
  static String createSuccessSavedTo(String path) => 'Saved to:\n$path';
  static const String createSuccessDownloaded = 'Downloaded to your browser\'s '
      'downloads.';

  // ---- Getting a private-app-storage backup out of the app ----
  // (Android/iOS - see BackupSaveLocation.isPrivateAppStorage.)
  static const String exportOfferTitle = 'Get this backup out of the app';
  static const String exportOfferBody =
      'This backup is currently only stored inside this app. It will be lost '
      'if the app is uninstalled or the phone is lost. Choose where to keep '
      'it:';
  static const String exportOfferWarning =
      'This backup is ONLY inside the app right now and will be lost with '
      'the app. Choose one of the options below to keep it safe.';
  static const String exportSaveAsButton = 'Save to…';
  static const String exportShareButton = 'Share…';
  static String exportSavedTo(String where) => 'Saved to:\n$where';
  static const String exportSharedTitle = 'Shared';
  static const String exportSharedBody =
      'The backup was handed off to share. Once that finishes, it will be '
      'safe outside this app.';
  static const String exportFailedTitle = 'Could not export the backup';
  static String exportFailed(String message) =>
      'That didn\'t work: $message\n\nThe backup is still safe inside the app - '
      'you can try again.';

  static const String createFailedTitle = 'Backup failed';
  static const String createCancelledTitle = 'Backup cancelled';
  static const String createCancelledBody = 'No file was saved.';

  // ---- Restore flow ----
  static const String pickFileTitle = 'Choose a backup file';
  static const String restorePreviewTitle = 'This backup contains';
  static String restorePreviewCreatedAt(String when) => 'Made on $when';
  static const String restorePreviewConfirm = 'Restore';
  static const String restorePreviewCancel = 'Cancel';
  static const String restorePreviewExplain =
      'Restoring merges this backup into what\'s already on this device. '
      'Nothing already here is deleted; when the same story/person/place '
      'exists in both, the most recently edited version wins.';

  static const String restoringTitle = 'Restoring…';

  static const String restoreFailedTitle = 'Could not restore this backup';

  static const String restoreResultTitle = 'Restore complete';
  static String restoreResultEntities(int added, int updated, int skipped) =>
      '$added added, $updated updated, $skipped already up to date';
  static String restoreResultRecordings(int restored, int alreadyPresent) =>
      '$restored recording${restored == 1 ? '' : 's'} restored'
      '${alreadyPresent > 0 ? ', $alreadyPresent already on this device' : ''}';
  static const String restoreWarningsTitle = 'Warnings';
  static String recordingConflictWarning(String id) =>
      'Recording $id: this device already has a different recording with '
      'that id. The existing one was kept.';
  static String recordingChecksumWarning(String id) =>
      'Recording $id: its data in the archive is corrupted (failed the '
      'checksum check) and was not restored.';
  static String recordingInvalidIdWarning(String id) =>
      'Recording entry "$id" has an invalid id and was ignored.';

  // ---- Formatting helpers used by result/preview text ----
  static String bytesToHuman(int bytes) {
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(0)} KB';
    return '$bytes B';
  }
}
