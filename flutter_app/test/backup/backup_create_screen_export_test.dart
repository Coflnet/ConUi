// Widget tests for BackupCreateScreen's Android/iOS "Save to..."/
// "Share..." export offer (see lib/backup/backup_export.dart and
// BackupSaveLocation.isPrivateAppStorage): once a backup is verified and
// committed to this app's own private storage, the screen must offer a
// real destination rather than reporting the job done, and must keep
// offering both actions if either dialog is cancelled - see the brief's
// "if the user cancels both dialogs" rule.
//
// Runs against a REAL BackupService/DatabaseService/NativeRecordingFileStore
// (like backup_service_integration_test.dart) so the whole
// plan -> create -> verify -> commit sequence is exercised for real; only
// the destination (TempDirBackupDestinationProvider, told to report
// isPrivateAppStorage like Android/iOS would) and the export offer itself
// (FakeBackupExportOffer, standing in for flutter_file_dialog/share_plus)
// are faked.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/backup/backup_create_screen.dart';
import 'package:relationship_manager/backup/backup_service.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/services/recording_file_store_native.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/localized_app.dart';
import '../support/test_database.dart';
import 'fake_destination.dart';
import 'fake_export_offer.dart';

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
    tempRoot = Directory.systemTemp.createTempSync('backup_create_export_test');
  });

  tearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  Future<BackupService> buildService({required bool isPrivateAppStorage}) async {
    final db = createTestDatabaseService();
    await db.initialize();
    await db.savePerson(Person(id: 'p1', name: 'Ada'));
    final storeDir = Directory('${tempRoot.path}/store')..createSync();
    final outDir = Directory('${tempRoot.path}/out')..createSync();
    return BackupService(
      databaseService: db,
      recordingStore: NativeRecordingFileStore(baseDirectory: storeDir),
      destinationProviderFactory: () =>
          TempDirBackupDestinationProvider(outDir, isPrivateAppStorage: isPrivateAppStorage),
    );
  }

  /// Pumps the screen, taps "Create backup" and waits for it to finish -
  /// lands on whatever the "done" step shows (plain summary, or the export
  /// offer).
  Future<void> runBackupToDone(
      WidgetTester tester, BackupService service, FakeBackupExportOffer exportOffer) async {
    await tester.pumpWidget(wrapLocalized(
      BackupCreateScreen(backupService: service, exportOffer: exportOffer),
    ));
    await _settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Create backup'));
    await _settle(tester, rounds: 100);
  }

  testWidgets(
      'desktop-style destination (isPrivateAppStorage=false) shows "Saved to" directly, '
      'no export offer', (tester) async {
    late BackupService service;
    await tester.runAsync(() async {
      service = await buildService(isPrivateAppStorage: false);
    });

    await runBackupToDone(tester, service, FakeBackupExportOffer());

    expect(find.text('Get this backup out of the app'), findsNothing);
    expect(find.textContaining('Saved to:'), findsOneWidget);
  });

  testWidgets(
      'private-app-storage destination (Android/iOS) offers Save to.../Share... instead '
      'of reporting done', (tester) async {
    late BackupService service;
    await tester.runAsync(() async {
      service = await buildService(isPrivateAppStorage: true);
    });

    await runBackupToDone(tester, service, FakeBackupExportOffer());

    expect(find.text('Get this backup out of the app'), findsOneWidget);
    expect(find.text('Save to…'), findsOneWidget);
    expect(find.text('Share…'), findsOneWidget);
    // The plain "Saved to" summary (which would be misleading here - the
    // file hasn't left the app yet) must not be shown at the same time.
    expect(find.textContaining('Saved to:'), findsNothing);
  });

  testWidgets('choosing Save to... shows where it ended up and deletes the temp copy',
      (tester) async {
    late BackupService service;
    await tester.runAsync(() async {
      service = await buildService(isPrivateAppStorage: true);
    });
    final exportOffer = FakeBackupExportOffer()
      ..nextSaveAsResult = '/sdcard/Documents/backup.zip';

    await runBackupToDone(tester, service, exportOffer);
    await tester.tap(find.text('Save to…'));
    await _settle(tester);

    expect(find.textContaining('/sdcard/Documents/backup.zip'), findsOneWidget);
    expect(exportOffer.deletedPaths, hasLength(1));
    expect(find.text('Get this backup out of the app'), findsNothing);
  });

  testWidgets(
      'cancelling Save to... keeps both options on screen with a stronger warning, and '
      'does not delete the temp copy', (tester) async {
    late BackupService service;
    await tester.runAsync(() async {
      service = await buildService(isPrivateAppStorage: true);
    });
    final exportOffer = FakeBackupExportOffer()..nextSaveAsResult = null;

    await runBackupToDone(tester, service, exportOffer);
    await tester.tap(find.text('Save to…'));
    await _settle(tester);

    expect(find.text('This backup is ONLY inside the app right now and will be lost with the app. Choose one of the options below to keep it safe.'), findsOneWidget);
    expect(find.text('Save to…'), findsOneWidget);
    expect(find.text('Share…'), findsOneWidget);
    expect(exportOffer.deletedPaths, isEmpty);
  });

  testWidgets(
      'choosing Share... that completes shows a Shared confirmation and deletes the temp copy',
      (tester) async {
    late BackupService service;
    await tester.runAsync(() async {
      service = await buildService(isPrivateAppStorage: true);
    });
    final exportOffer = FakeBackupExportOffer()..nextShareResult = true;

    await runBackupToDone(tester, service, exportOffer);
    await tester.tap(find.text('Share…'));
    await _settle(tester);

    expect(find.text('Shared'), findsOneWidget);
    expect(exportOffer.deletedPaths, hasLength(1));
  });

  testWidgets('dismissing the share sheet keeps both options on screen, still offered again',
      (tester) async {
    late BackupService service;
    await tester.runAsync(() async {
      service = await buildService(isPrivateAppStorage: true);
    });
    final exportOffer = FakeBackupExportOffer()..nextShareResult = false;

    await runBackupToDone(tester, service, exportOffer);
    await tester.tap(find.text('Share…'));
    await _settle(tester);

    expect(find.text('This backup is ONLY inside the app right now and will be lost with the app. Choose one of the options below to keep it safe.'), findsOneWidget);
    expect(find.text('Save to…'), findsOneWidget);
    expect(find.text('Share…'), findsOneWidget);
    expect(exportOffer.deletedPaths, isEmpty);
  });
}
