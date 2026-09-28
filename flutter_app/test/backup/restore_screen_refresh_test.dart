// Regression coverage for the "Done" action after a SUCCESSFUL restore
// (see restore_screen.dart's _finishSuccessfulRestore): screens already
// open elsewhere in the app mostly loaded their data once in initState
// (see the final report for exactly which), so simply popping back one
// screen would leave them showing pre-restore data indefinitely. "Done"
// must instead pop all the way back to the app's first route AND notify
// DatabaseService, so routes popped past here reload fresh next time
// they're pushed, and any screen still on the stack that DOES listen to
// DatabaseService picks the change up immediately.
//
// Swaps in a fake FilePicker platform implementation (see
// backup_service_cache_cleanup_test.dart's doc comment for why) so
// RestoreScreen's real pickBackupFile() call hands back a real backup file
// this test built with a real (temp-dir-backed) BackupService, rather than
// needing an actual SAF/document-picker dialog.
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:relationship_manager/backup/backup_service.dart';
import 'package:relationship_manager/backup/backup_strings.dart';
import 'package:relationship_manager/backup/restore_screen.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/recording_file_store_native.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';
import 'fake_destination.dart';

/// Hands back [path] from pickFiles(), exactly as file_picker would once
/// the user picks a real file (see pickBackupFile()'s doc comment for why
/// this is a real filesystem path even on Android - a cache copy, but a
/// real file either way).
class _FakeFilePickerWithPath extends FilePicker {
  final String path;
  _FakeFilePickerWithPath(this.path);

  @override
  Future<FilePickerResult?> pickFiles({
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileLoading,
    bool? allowCompression,
    bool allowMultiple = false,
    bool? withData,
    int compressionQuality = 0,
    bool? withReadStream,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    return FilePickerResult(
        [PlatformFile(name: 'backup.zip', path: path, size: await File(path).length())]);
  }

  @override
  Future<bool?> clearTemporaryFiles() async => true;
}

Future<void> _settle(WidgetTester tester, {int rounds = 60}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
}

void main() {
  late Directory tempRoot;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tempRoot = Directory.systemTemp.createTempSync('restore_refresh_test');
  });

  tearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  testWidgets(
      '"Done" after a successful restore pops past every intermediate screen back to '
      'the first route and notifies DatabaseService', (tester) async {
    late String backupPath;
    late DatabaseService destDb;
    late BackupService restoreService;

    await tester.runAsync(() async {
      // A real backup .zip, made from a small separate "source" database -
      // exactly how a real backup file was produced, just without a UI.
      final sourceDb = createTestDatabaseService();
      await sourceDb.initialize();
      await sourceDb.savePerson(Person(id: 'p1', name: 'Ada'));
      final sourceStoreDir = Directory('${tempRoot.path}/sourceStore')..createSync();
      final outDir = Directory('${tempRoot.path}/out')..createSync();
      final sourceService = BackupService(
        databaseService: sourceDb,
        recordingStore: NativeRecordingFileStore(baseDirectory: sourceStoreDir),
        destinationProviderFactory: () => TempDirBackupDestinationProvider(outDir),
      );
      final outcome = await sourceService.createBackup();
      backupPath = (outcome as BackupCreateSuccess).location.description;

      // A fresh, empty destination database/store to restore INTO.
      destDb = createTestDatabaseService();
      await destDb.initialize();
      final destStoreDir = Directory('${tempRoot.path}/destStore')..createSync();
      restoreService = BackupService(
        databaseService: destDb,
        recordingStore: NativeRecordingFileStore(baseDirectory: destStoreDir),
      );
    });

    FilePicker.platform = _FakeFilePickerWithPath(backupPath);

    var notifyCount = 0;
    destDb.addListener(() => notifyCount++);

    // HOME (first route) -> SETTINGS (an intermediate pushed route,
    // standing in for SettingsScreen) -> RestoreScreen - all pushed on
    // MaterialApp's own Navigator, exactly like settings_screen_backup_test.
    // dart's "renders inside a Scaffold..." test pushes SettingsScreen, so
    // this reuses the same proven shape rather than a custom nested
    // Navigator.
    await tester.pumpWidget(
      ChangeNotifierProvider<DatabaseService>.value(
        value: destDb,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (context) => Scaffold(
                      body: Center(
                        child: ElevatedButton(
                          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => RestoreScreen(backupService: restoreService),
                          )),
                          child: const Text('SETTINGS'),
                        ),
                      ),
                    ),
                  )),
                  child: const Text('HOME'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await _settle(tester);
    await tester.tap(find.text('HOME'));
    await _settle(tester);
    await tester.tap(find.text('SETTINGS'));
    await _settle(tester, rounds: 100); // pick + preview the real backup file

    expect(find.text(BackupStrings.restorePreviewConfirm), findsOneWidget,
        reason: 'expected the restore preview to be showing by now');

    await tester.tap(find.text(BackupStrings.restorePreviewConfirm));
    await _settle(tester, rounds: 100); // run the actual restore

    expect(find.text('Done'), findsOneWidget,
        reason: 'expected the restore to have completed successfully by now');
    await tester.tap(find.text('Done'));
    await _settle(tester);

    expect(find.text('SETTINGS'), findsNothing,
        reason: '"Done" must pop past SETTINGS too, not just back to it');
    expect(find.text('HOME'), findsOneWidget);
    expect(notifyCount, greaterThan(0),
        reason: 'DatabaseService.notifyDataRestored() must have fired');

    // A direct `await` on real sqflite I/O here (rather than through a
    // widget interaction `_settle()` can pump) needs `runAsync` too - see
    // this file's doc comment / settings_screen_backup_test.dart's note on
    // why sqflite_common_ffi doesn't resolve inside testWidgets' FakeAsync
    // zone otherwise.
    final restoredPerson = await tester.runAsync(() => destDb.getPerson('p1'));
    expect(restoredPerson?.name, 'Ada'); // sanity: the restore itself really ran
  }, timeout: const Timeout(Duration(seconds: 30)));
}
