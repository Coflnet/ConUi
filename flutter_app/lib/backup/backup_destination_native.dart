import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart' as fp;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'backup_destination.dart';

BackupDestinationProvider createBackupDestinationProvider() =>
    _NativeBackupDestinationProvider();

bool get _isDesktop => Platform.isLinux || Platform.isMacOS || Platform.isWindows;

/// Desktop (Linux/macOS/Windows): file_picker's `saveFile` is implemented on
/// these three platforms - see its own doc comment ("For desktop
/// platforms, this function opens a dialog...") - so only here can the
/// user actually choose where the backup goes directly.
///
/// Android/iOS: file_picker's `saveFile` requires the WHOLE file as
/// in-memory `bytes` on these platforms (checked against the currently
/// installed version - see the final report), which defeats the point of
/// streaming a multi-hundred-MB recording, so it isn't used here at all.
/// Instead the backup is written to this app's own documents directory
/// under `backups/`; [BackupSaveLocation.isPrivateAppStorage] tells the UI
/// this isn't a real resting place yet, and offering the user a real one
/// (system "Save to..."/"Share...") is [BackupExportOffer]'s job - see
/// backup_export.dart and backup_create_screen.dart.
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
    final bool isPrivateAppStorage;
    if (_isDesktop) {
      final chosen = await fp.FilePicker.platform.saveFile(
        dialogTitle: 'Save backup',
        fileName: suggestedFileName,
        type: fp.FileType.custom,
        allowedExtensions: ['zip'],
      );
      if (chosen == null) return null; // user cancelled the dialog
      finalPath = chosen.toLowerCase().endsWith('.zip') ? chosen : '$chosen.zip';
      isPrivateAppStorage = false;
    } else {
      final docs = await getApplicationDocumentsDirectory();
      final backupsDir = Directory(p.join(docs.path, 'backups'));
      if (!await backupsDir.exists()) {
        await backupsDir.create(recursive: true);
      } else {
        // This app-private copy is only ever meant to be temporary - see
        // isPrivateAppStorage's doc comment - so anything already sitting
        // here is a leftover from a previous run whose export the user
        // never finished (or that this same cleanup missed after a crash).
        // Starting a NEW backup makes those stale, so clear them out now
        // rather than letting them accumulate and fill up the device.
        await _deleteExistingBackupFiles(backupsDir);
      }
      finalPath = p.join(backupsDir.path, suggestedFileName);
      isPrivateAppStorage = true;
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
      isPrivateAppStorage: isPrivateAppStorage,
    );
  }
}

/// Deletes every file already in [backupsDir] - see the "temporary only"
/// contract on [BackupSaveLocation.isPrivateAppStorage]. Best-effort: a
/// file that can't be deleted (e.g. still open) is left for next time
/// rather than failing the new backup over it.
Future<void> _deleteExistingBackupFiles(Directory backupsDir) async {
  await for (final entity in backupsDir.list()) {
    if (entity is! File) continue;
    try {
      await entity.delete();
    } catch (_) {
      // Best-effort cleanup - see doc comment above.
    }
  }
}

class _NativeBackupWriteTarget implements BackupWriteTarget {
  @override
  final OutputStream output;
  final String tempPath;
  final String finalPath;
  final bool isPrivateAppStorage;
  bool _finished = false;

  _NativeBackupWriteTarget(
      {required this.output,
      required this.tempPath,
      required this.finalPath,
      required this.isPrivateAppStorage});

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
    return BackupSaveLocation(
        description: finalPath, isFilePath: true, isPrivateAppStorage: isPrivateAppStorage);
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
