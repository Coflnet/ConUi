// Widget tests for the backup/restore additions to SettingsScreen:
//  - the pre-existing bug where the screen returned a bare ListView with no
//    Scaffold/AppBar despite being pushed as a full route (see the final
//    report) is fixed and stays fixed;
//  - "Create backup"/"Restore from backup" replace the old "coming soon"
//    Export/Import Data placeholders;
//  - last-backup date, the "recordings since backup" reminder, and
//    recordings space usage render correctly.
//
// Like other screens that touch the database, these run their async setup
// through tester.runAsync() (see widget_test.dart's note - sqflite_common_ffi
// doesn't resolve inside testWidgets' FakeAsync zone) and SharedPreferences
// through its test-mode mock storage (BackupService.getLastBackupAt() goes
// through SharedPreferences).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:relationship_manager/backup/backup_service.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/screens/settings_screen.dart';
import 'package:relationship_manager/services/auth_service.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/recording_file_store_native.dart';
import 'package:relationship_manager/services/sync_service.dart';

import '../support/test_database.dart';

Widget _wrap({
  required DatabaseService db,
  required BackupService backupService,
}) {
  return MaterialApp(
    home: MultiProvider(
      providers: [
        ChangeNotifierProvider<DatabaseService>.value(value: db),
        ChangeNotifierProvider<AuthService>(create: (_) => AuthService()),
        Provider<SyncService>(create: (_) => SyncService(db, AuthService())),
      ],
      child: SettingsScreen(backupService: backupService),
    ),
  );
}

/// Pumps until the async initState loads (sync status, then backup status:
/// last-backup time, recordings space, recordings-since-backup - three
/// sequential real I/O awaits) have settled, the same way
/// event_detail_screen_test.dart does for its single FutureBuilder query,
/// just repeated enough times to drain a chain of several real-async gaps
/// rather than just one.
Future<void> _settle(WidgetTester tester, {int rounds = 40, bool Function()? until}) async {
  for (var i = 0; i < rounds; i++) {
    if (until != null && until()) return;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('renders inside a Scaffold with an AppBar when pushed as a route',
      (tester) async {
    late DatabaseService db;
    late Directory tempDir;
    await tester.runAsync(() async {
      db = createTestDatabaseService();
      await db.initialize();
      tempDir = Directory.systemTemp.createTempSync('settings_screen_test');
    });
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    final backupService = BackupService(
      databaseService: db,
      recordingStore: NativeRecordingFileStore(baseDirectory: tempDir),
    );

    // Push it as a full route, exactly like HomeScreen does
    // (MaterialPageRoute(builder: (_) => const SettingsScreen())). The
    // MultiProvider has to sit ABOVE MaterialApp/its Navigator, not inside
    // `home:` - providers placed inside one route's page aren't visible to
    // a DIFFERENT (pushed) route, only to ancestors of the Navigator.
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<DatabaseService>.value(value: db),
        ChangeNotifierProvider<AuthService>(create: (_) => AuthService()),
        Provider<SyncService>(create: (_) => SyncService(db, AuthService())),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => SettingsScreen(backupService: backupService)),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await _settle(tester);

    expect(find.byType(Scaffold), findsWidgets);
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('shows Create backup / Restore from backup instead of the old '
      'Export/Import Data placeholders', (tester) async {
    late DatabaseService db;
    late Directory tempDir;
    await tester.runAsync(() async {
      db = createTestDatabaseService();
      await db.initialize();
      tempDir = Directory.systemTemp.createTempSync('settings_screen_test');
    });
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final backupService = BackupService(
      databaseService: db,
      recordingStore: NativeRecordingFileStore(baseDirectory: tempDir),
    );

    await tester.pumpWidget(_wrap(db: db, backupService: backupService));
    await _settle(tester);

    expect(find.text('Create backup'), findsOneWidget);
    expect(find.text('Restore from backup'), findsOneWidget);
    expect(find.text('Export Data'), findsNothing);
    expect(find.text('Import Data'), findsNothing);
    expect(find.text('Export feature coming soon'), findsNothing);
  });

  testWidgets('shows "no backup yet" when none has been made', (tester) async {
    late DatabaseService db;
    late Directory tempDir;
    await tester.runAsync(() async {
      db = createTestDatabaseService();
      await db.initialize();
      tempDir = Directory.systemTemp.createTempSync('settings_screen_test');
    });
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final backupService = BackupService(
      databaseService: db,
      recordingStore: NativeRecordingFileStore(baseDirectory: tempDir),
    );

    await tester.pumpWidget(_wrap(db: db, backupService: backupService));
    await _settle(tester);

    expect(find.text('No backup has been made yet'), findsOneWidget);
  });

  testWidgets('shows the last backup date and a reminder about new recordings',
      (tester) async {
    late DatabaseService db;
    late Directory tempDir;
    await tester.runAsync(() async {
      db = createTestDatabaseService();
      await db.initialize();
      tempDir = Directory.systemTemp.createTempSync('settings_screen_test');
    });
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final backupService = BackupService(
      databaseService: db,
      recordingStore: NativeRecordingFileStore(baseDirectory: tempDir),
    );

    final longAgo = DateTime.now().subtract(const Duration(days: 30));
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues(
          {'backup_last_success_at': longAgo.toIso8601String()});
      // A recording made after that "last backup".
      final store = NativeRecordingFileStore(baseDirectory: tempDir);
      await store.beginRecording('rec1');
      await store.appendChunk('rec1', Uint8List(100));
      await store.finalizeRecording('rec1');
      await db.saveLocalRecording(LocalRecordingState(
        id: 'rec1',
        state: RecordingLifecycleState.complete,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));
    });

    await tester.pumpWidget(_wrap(db: db, backupService: backupService));
    await _settle(tester);

    expect(find.textContaining('Last backup:'), findsOneWidget);
    expect(find.text('1 recording was made since your last backup'), findsOneWidget);
  });

  testWidgets('shows how much space recordings use on this device', (tester) async {
    late DatabaseService db;
    late Directory tempDir;
    await tester.runAsync(() async {
      db = createTestDatabaseService();
      await db.initialize();
      tempDir = Directory.systemTemp.createTempSync('settings_screen_test');
      final store = NativeRecordingFileStore(baseDirectory: tempDir);
      await store.beginRecording('rec1');
      await store.appendChunk('rec1', Uint8List(1000));
      await store.finalizeRecording('rec1');
    });
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final backupService = BackupService(
      databaseService: db,
      recordingStore: NativeRecordingFileStore(baseDirectory: tempDir),
    );

    await tester.pumpWidget(_wrap(db: db, backupService: backupService));
    await _settle(tester);

    expect(find.text('Recordings on this device'), findsOneWidget);
    // 44-byte WAV header + 1000 bytes of PCM = 1044 bytes -> "1 KB" per
    // BackupStrings.bytesToHuman's rounding.
    expect(find.text('1 KB'), findsOneWidget);
  });
}
