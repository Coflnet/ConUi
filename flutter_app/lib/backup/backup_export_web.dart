// On web, BackupDestinationProvider already triggers a browser download
// (see backup_destination_web.dart) - there is no app-private copy left
// over to export further, so this offer has nothing to do. It exists only
// so backup_export.dart's conditional import always resolves.
import 'backup_export.dart';

BackupExportOffer createBackupExportOffer() => _WebBackupExportOffer();

class _WebBackupExportOffer implements BackupExportOffer {
  @override
  bool get needsExport => false;

  @override
  Future<String?> saveAs({required String sourceFilePath, required String suggestedFileName}) {
    throw UnsupportedError('saveAs() is never called on web - needsExport is false.');
  }

  @override
  Future<bool> share({required String sourceFilePath, required String suggestedFileName}) {
    throw UnsupportedError('share() is never called on web - needsExport is false.');
  }

  @override
  Future<void> deleteTemporaryCopy(String path) async {
    // Nothing to delete - see this file's doc comment.
  }
}
