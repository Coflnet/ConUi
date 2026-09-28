// A BackupExportOffer test double, so BackupCreateScreen's Android/iOS
// "Save to..."/"Share..." offer (see lib/backup/backup_export.dart) can be
// exercised without flutter_file_dialog/share_plus's real platform
// channels.
import 'package:relationship_manager/backup/backup_export.dart';

class FakeBackupExportOffer implements BackupExportOffer {
  @override
  bool needsExport = true;

  /// What the next [saveAs] call returns - null simulates the user
  /// cancelling the SAF dialog.
  String? nextSaveAsResult;

  /// What the next [share] call returns - false simulates the user
  /// dismissing the share sheet without picking a target.
  bool nextShareResult = true;

  /// When set, the next [saveAs] call throws this instead of returning.
  Object? saveAsError;

  /// When set, the next [share] call throws this instead of returning.
  Object? shareError;

  final List<String> saveAsRequests = [];
  final List<String> shareRequests = [];
  final List<String> deletedPaths = [];

  @override
  Future<String?> saveAs(
      {required String sourceFilePath, required String suggestedFileName}) async {
    saveAsRequests.add(sourceFilePath);
    final error = saveAsError;
    if (error != null) throw error;
    return nextSaveAsResult;
  }

  @override
  Future<bool> share({required String sourceFilePath, required String suggestedFileName}) async {
    shareRequests.add(sourceFilePath);
    final error = shareError;
    if (error != null) throw error;
    return nextShareResult;
  }

  @override
  Future<void> deleteTemporaryCopy(String path) async {
    deletedPaths.add(path);
  }
}
