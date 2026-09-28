import 'dart:io';

import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:share_plus/share_plus.dart'; // also re-exports XFile

import 'backup_export.dart';

BackupExportOffer createBackupExportOffer() => _NativeBackupExportOffer();

/// Only Android/iOS actually need exporting - see [BackupSaveLocation.
/// isPrivateAppStorage]'s doc comment; desktop's BackupDestinationProvider
/// already asked the user where to save via file_picker's `saveFile`, which
/// IS implemented there.
bool get _needsExport => Platform.isAndroid || Platform.isIOS;

/// [saveAs] uses `flutter_file_dialog` rather than file_picker's own
/// `saveFile`: file_picker's Android/iOS implementation requires the whole
/// file as in-memory `bytes` (see backup_destination_native.dart's doc
/// comment), while flutter_file_dialog's [SaveFileDialogParams.
/// sourceFilePath] streams straight from the file on the native (Kotlin/
/// Swift) side of the plugin - the Dart side never reads the backup into
/// memory either way.
///
/// [share] uses `share_plus`'s [XFile], which on Android/iOS also just
/// wraps a file path - the platform's share sheet (`ACTION_SEND`/
/// `UIActivityViewController`) streams the file to whatever app the user
/// picks via a content:// Uri / FileProvider, again without this app
/// reading it into memory.
class _NativeBackupExportOffer implements BackupExportOffer {
  @override
  bool get needsExport => _needsExport;

  @override
  Future<String?> saveAs(
      {required String sourceFilePath, required String suggestedFileName}) async {
    return FlutterFileDialog.saveFile(
      params: SaveFileDialogParams(
        sourceFilePath: sourceFilePath,
        fileName: suggestedFileName,
        mimeTypesFilter: const ['application/zip'],
      ),
    );
  }

  @override
  Future<bool> share(
      {required String sourceFilePath, required String suggestedFileName}) async {
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [XFile(sourceFilePath, mimeType: 'application/zip')],
        fileNameOverrides: [suggestedFileName],
      ),
    );
    // ShareResultStatus.unavailable means the platform couldn't report
    // whether anything happened (see ShareResult's doc comment) - treated
    // as "assume it went through" rather than bouncing the user back to
    // the same two buttons for a signal that will never arrive. Only an
    // explicit `dismissed` means the user backed out without picking
    // anything.
    return result.status != ShareResultStatus.dismissed;
  }

  @override
  Future<void> deleteTemporaryCopy(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }
}
