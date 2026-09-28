// Integration test for BackupService wired to the REAL DatabaseService
// (sqflite_common_ffi, in-memory) and the REAL native RecordingFileStore
// (temp-directory-backed), going through DatabaseBackupAdapter exactly as
// the app does. The pure-logic tests (backup_writer_test.dart,
// backup_restorer_test.dart, round_trip_test.dart) use fakes for speed;
// this test exists to catch wiring bugs those can't - wrong column names,
// month_key/connection column derivation, event_id backfill, pending
// changes, and the real streaming file destination.
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/backup/backup_service.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/recording_file_store_native.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/test_database.dart';
import 'fake_destination.dart';
import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempRoot;

  setUp(() {
    // BackupService.getLastBackupAt()/_recordLastBackupAt() go through
    // SharedPreferences, which needs its test-mode mock storage (matches
    // widget_test.dart's setUp) even though these are plain test()s, not
    // testWidgets() - SharedPreferences talks over a platform channel that
    // only TestWidgetsFlutterBinding + this mock intercept.
    SharedPreferences.setMockInitialValues({});
    tempRoot = Directory.systemTemp.createTempSync('backup_service_test');
  });

  tearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  test('creates a verified backup file on a real temp directory and it previews correctly',
      () async {
    final db = createTestDatabaseService();
    await db.initialize();
    final storeDir = Directory('${tempRoot.path}/store')..createSync();
    final store = NativeRecordingFileStore(baseDirectory: storeDir);
    final outDir = Directory('${tempRoot.path}/out')..createSync();

    final person = Person(id: 'p1', name: 'Ada');
    await db.savePerson(person);

    final service = BackupService(
      databaseService: db,
      recordingStore: store,
      destinationProviderFactory: () => TempDirBackupDestinationProvider(outDir),
    );

    final outcome = await service.createBackup();
    expect(outcome, isA<BackupCreateSuccess>());
    final success = outcome as BackupCreateSuccess;
    expect(File(success.location.description).existsSync(), isTrue);
    expect(success.manifest.counts['persons'], 1);

    // The file left behind must be exactly the finished backup - no stray
    // .tmp file alongside it.
    final leftoverTmp = File('${success.location.description}.tmp');
    expect(leftoverTmp.existsSync(), isFalse);

    final picked = PickedBackupFile(() => InputFileStream(success.location.description));
    // Reads the SAME PickedBackupFile twice (preview, then a second
    // preview standing in for the apply() call every real restore also
    // makes) - regression coverage for a bug the browser E2E check caught:
    // InputStream is a stateful, position-advancing reader, so handing out
    // one already-opened stream for both reads left the second one unable
    // to find the central directory at all. PickedBackupFile.open() must
    // give back a FRESH stream each time.
    final preview1 = service.previewRestore(picked);
    final preview2 = service.previewRestore(picked);
    expect(preview1.manifest.counts['persons'], 1);
    expect(preview2.manifest.counts['persons'], 1);

    expect(await service.getLastBackupAt(), isNotNull);
  });

  test('a cancelled backup leaves no partial file behind', () async {
    final db = createTestDatabaseService();
    await db.initialize();
    final storeDir = Directory('${tempRoot.path}/store')..createSync();
    final store = NativeRecordingFileStore(baseDirectory: storeDir);
    final outDir = Directory('${tempRoot.path}/out')..createSync();

    await db.savePerson(Person(id: 'p1', name: 'Ada'));

    final service = BackupService(
      databaseService: db,
      recordingStore: store,
      destinationProviderFactory: () => TempDirBackupDestinationProvider(outDir),
    );

    final outcome = await service.createBackup(isCancelled: () => true);
    expect(outcome, isA<BackupCreateCancelled>());
    expect(outDir.listSync(), isEmpty);
  });

  test('restores a real backup from one device into a fresh second device, '
      'including recording bytes', () async {
    // "Device A": makes a backup.
    final dbA = createTestDatabaseService();
    await dbA.initialize();
    final storeDirA = Directory('${tempRoot.path}/storeA')..createSync();
    final storeA = NativeRecordingFileStore(baseDirectory: storeDirA);
    final outDir = Directory('${tempRoot.path}/out')..createSync();

    await dbA.savePerson(Person(id: 'p1', name: 'Ada Lovelace'));
    final wav = buildTestWav(3000, seed: 42);
    await storeA.beginRecording('rec1');
    await storeA.appendChunk('rec1', wav.sublist(44));
    await storeA.finalizeRecording('rec1');
    await dbA.saveEvent(Event(
      id: 'e1',
      title: 'A story',
      dateTime: DateTime(2020, 5, 1),
      files: [
        AttachedFile(
          id: 'rec1',
          fileName: 'rec1.wav',
          filePath: 'rec1.wav',
          mimeType: 'audio/wav',
          size: wav.length,
          kind: AttachedFile.kindRecording,
        ),
      ],
    ));

    final serviceA = BackupService(
      databaseService: dbA,
      recordingStore: storeA,
      destinationProviderFactory: () => TempDirBackupDestinationProvider(outDir),
    );
    final outcome = await serviceA.createBackup();
    final backupPath = (outcome as BackupCreateSuccess).location.description;

    // "Device B": fresh database, fresh recording store, restores the file.
    // Deliberately NOT createTestDatabaseService() here: sqflite_common_ffi
    // caches open databases by path with singleInstance=true by default, so
    // two DatabaseServices both opened at the literal `inMemoryDatabasePath`
    // string (":memory:") end up sharing the SAME underlying database
    // rather than being independent - which silently turned this
    // "restore onto a fresh device" test into a same-device no-op the first
    // time it was written. A distinct real temp-file path keeps this
    // "device" genuinely separate.
    sqfliteFfiInit();
    final dbB =
        DatabaseService(factory: databaseFactoryFfi, path: '${tempRoot.path}/deviceB.db');
    await dbB.initialize();
    final storeDirB = Directory('${tempRoot.path}/storeB')..createSync();
    final storeB = NativeRecordingFileStore(baseDirectory: storeDirB);
    final serviceB = BackupService(databaseService: dbB, recordingStore: storeB);

    // Mirrors exactly what RestoreScreen does: preview the picked file
    // first, then apply the SAME PickedBackupFile - the real-world sequence
    // that caught the stateful-InputStream bug above.
    final picked = PickedBackupFile(() => InputFileStream(backupPath));
    final preview = serviceB.previewRestore(picked);
    expect(preview.manifest.counts['persons'], 1);

    final result = await serviceB.applyRestore(picked);
    expect(result.recordingsRestoredCount, 1);
    expect(result.addedCount, 2); // person + event

    final restoredPerson = await dbB.getPerson('p1');
    expect(restoredPerson?.name, 'Ada Lovelace');

    final restoredEvent = await dbB.getEvent('e1');
    expect(restoredEvent, isNotNull);
    expect(restoredEvent!.monthKey, '2020-05');

    final restoredBytes = await storeB.readBytes('rec1');
    expect(restoredBytes, wav);

    // The recording's local bookkeeping row must have been linked to the
    // story that references it.
    final localRecording = await dbB.getLocalRecording('rec1');
    expect(localRecording?.eventId, 'e1');

    // Restoring must have queued a pending change so this reaches other
    // devices via the normal sync path.
    final pending = await dbB.getPendingChanges();
    expect(pending.any((c) => c.entityType == 'event' && c.entityId == 'e1'), isTrue);
  });
}
