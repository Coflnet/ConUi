// A BackupDestinationProvider backed by a real temp directory, so tests can
// exercise BackupService's real streaming write/verify/commit/abort
// sequencing (see backup_destination_native.dart, which this mirrors)
// without going through file_picker/path_provider platform channels.
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:relationship_manager/backup/backup_destination.dart';

class TempDirBackupDestinationProvider implements BackupDestinationProvider {
  final Directory dir;

  /// When true, the next [prepareTarget] call returns null (as if the user
  /// cancelled a save dialog) and resets itself.
  bool cancelNextPrepare = false;

  TempDirBackupDestinationProvider(this.dir);

  @override
  Future<BackupWriteTarget?> prepareTarget(String suggestedFileName) async {
    if (cancelNextPrepare) {
      cancelNextPrepare = false;
      return null;
    }
    final finalPath = p.join(dir.path, suggestedFileName);
    final tempPath = '$finalPath.tmp';
    return _TempDirBackupWriteTarget(
      output: OutputFileStream(tempPath),
      tempPath: tempPath,
      finalPath: finalPath,
    );
  }
}

class _TempDirBackupWriteTarget implements BackupWriteTarget {
  @override
  final OutputStream output;
  final String tempPath;
  final String finalPath;
  bool _finished = false;

  _TempDirBackupWriteTarget(
      {required this.output, required this.tempPath, required this.finalPath});

  @override
  Future<void> finish() async {
    await output.close();
    _finished = true;
  }

  @override
  Future<InputStream> openForVerification() async => InputFileStream(tempPath);

  @override
  Future<BackupSaveLocation> commit() async {
    if (!_finished) await finish();
    final finalFile = File(finalPath);
    if (await finalFile.exists()) await finalFile.delete();
    await File(tempPath).rename(finalPath);
    return BackupSaveLocation(description: finalPath, isFilePath: true);
  }

  @override
  Future<void> abort() async {
    if (!_finished) {
      try {
        await output.close();
      } catch (_) {}
    }
    final tempFile = File(tempPath);
    if (await tempFile.exists()) await tempFile.delete();
  }
}
