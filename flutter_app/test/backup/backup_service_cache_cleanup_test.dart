// Regression coverage for BackupService.clearPickedFileCache(): file_picker
// copies a picked Android/iOS document into this app's own cache directory
// (see pickBackupFile()'s doc comment and FilePickerIO.clearTemporaryFiles()
// existing for exactly this reason) rather than handing back a path to the
// original, so RestoreScreen must explicitly ask file_picker to clear that
// copy once a restore attempt is done with it - otherwise it lingers and
// fills up the device. Also covers that a failure to clear must never be
// allowed to block finishing/closing a restore (see restore_screen.dart's
// `finally`/close handlers, which call this without awaiting a result the
// user could act on).
//
// Swaps in a fake FilePicker platform implementation (the documented way to
// test a federated plugin - see FilePicker's own doc comment: "Platform
// implementations should extend this class") rather than mocking a
// MethodChannel: which concrete FilePicker implementation `.platform`
// resolves to for "this test's host platform" isn't something this test
// should have to know or depend on.
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/backup/backup_service.dart';

import '../support/test_database.dart';

class _FakeFilePicker extends FilePicker {
  int clearTemporaryFilesCalls = 0;
  Object? throwOnClear;

  @override
  Future<bool?> clearTemporaryFiles() async {
    clearTemporaryFilesCalls++;
    final error = throwOnClear;
    if (error != null) throw error;
    return true;
  }
}

void main() {
  test('clearPickedFileCache() asks file_picker to clear its temporary files', () async {
    final fake = _FakeFilePicker();
    FilePicker.platform = fake;

    final service = BackupService(databaseService: createTestDatabaseService());
    await service.clearPickedFileCache();

    expect(fake.clearTemporaryFilesCalls, 1);
  });

  test(
      'clearPickedFileCache() does not throw when file_picker fails to clear - '
      'best-effort cleanup must never block finishing a restore', () async {
    final fake = _FakeFilePicker()..throwOnClear = Exception('boom');
    FilePicker.platform = fake;

    final service = BackupService(databaseService: createTestDatabaseService());

    await expectLater(service.clearPickedFileCache(), completes);
    expect(fake.clearTemporaryFilesCalls, 1);
  });
}
