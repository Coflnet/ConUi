import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart' as fp;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'backup_destination.dart';

BackupDestinationProvider createBackupDestinationProvider() =>
    _NativeBackupDestinationProvider();

bool get _isDesktop => Platform.isLinux || Platform.isMacOS || Platform.isWindows;

/// Desktop (Linux/macOS/Windows): the installed file_picker version (6.2.1)
/// implements `saveFile` only on these three platforms - see its own doc
/// comment ("This method is only available on desktop platforms") - so
/// only here can the user actually choose where the backup goes.
///
/// Android/iOS: that same `saveFile` throws UnimplementedError on this
/// version, so there is no working "choose a location" affordance to call.
/// Instead the backup is written to this app's own documents directory
/// under `backups/`, and the resulting path is shown to the user - see the
/// final report for this deviation from the brief.
///
/// Either way, writing goes to `<final path>.tmp` first and is only
/// renamed into place in [_NativeBackupWriteTarget.commit], after
/// BackupRestorer.verify() has passed - so a half-written or failed backup
/// never looks like a finished one, and a crash mid-write leaves at most a
/// stray `.tmp` file next to it.
class _NativeBackupDestinationProvider implements BackupDestinationProvider {
  @override
  Future<BackupWriteTarget?> prepareTarget(String suggestedFileName) async {
    final String finalPath;
    if (_isDesktop) {
      final chosen = await fp.FilePicker.platform.saveFile(
        dialogTitle: 'Save backup',
        fileName: suggestedFileName,
        type: fp.FileType.custom,
        allowedExtensions: ['zip'],
      );
      if (chosen == null) return null; // user cancelled the dialog
      finalPath = chosen.toLowerCase().endsWith('.zip') ? chosen : '$chosen.zip';
    } else {
      final docs = await getApplicationDocumentsDirectory();
      final backupsDir = Directory(p.join(docs.path, 'backups'));
      if (!await backupsDir.exists()) {
        await backupsDir.create(recursive: true);
      }
      finalPath = p.join(backupsDir.path, suggestedFileName);
    }

    final tempPath = '$finalPath.tmp';
    final tempFile = File(tempPath);
    if (await tempFile.exists()) {
      // Stray leftover from a previous crashed/interrupted run.
      await tempFile.delete();
    }

    return _NativeBackupWriteTarget(
      output: OutputFileStream(tempPath),
      tempPath: tempPath,
      finalPath: finalPath,
    );
  }
}

class _NativeBackupWriteTarget implements BackupWriteTarget {
  @override
  final OutputStream output;
  final String tempPath;
  final String finalPath;
  bool _finished = false;

  _NativeBackupWriteTarget(
      {required this.output, required this.tempPath, required this.finalPath});

  @override
  Future<void> finish() async {
    await output.close();
    _finished = true;
  }

  @override
  Future<InputStream> openForVerification() async {
    return InputFileStream(tempPath);
  }

  @override
  Future<BackupSaveLocation> commit() async {
    if (!_finished) await finish();
    final finalFile = File(finalPath);
    if (await finalFile.exists()) {
      await finalFile.delete();
    }
    await File(tempPath).rename(finalPath);
    return BackupSaveLocation(description: finalPath, isFilePath: true);
  }

  @override
  Future<void> abort() async {
    if (!_finished) {
      try {
        await output.close();
      } catch (_) {
        // Already closed/broken - fine, we're cleaning up either way.
      }
    }
    final tempFile = File(tempPath);
    if (await tempFile.exists()) {
      await tempFile.delete();
    }
  }
}
