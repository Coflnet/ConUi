import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/recording_file_store_native.dart';
import 'package:relationship_manager/services/recording_recovery_service.dart';

import '../support/test_database.dart';

void main() {
  late Directory tempDir;
  late NativeRecordingFileStore store;
  late DatabaseService db;
  late RecordingRecoveryService recovery;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('recording_recovery_test');
    store = NativeRecordingFileStore(baseDirectory: tempDir);
    db = createTestDatabaseService();
    await db.initialize();
    recovery = RecordingRecoveryService(store, db);
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('repairs an orphaned "recording" row and marks it recovered',
      () async {
    await store.beginRecording('orphan1');
    await store.appendChunk('orphan1', Uint8List.fromList(List.filled(400, 7)));
    await db.saveLocalRecording(LocalRecordingState(
      id: 'orphan1',
      state: RecordingLifecycleState.recording,
    ));

    final recovered = await recovery.recoverIncompleteRecordings();

    expect(recovered, hasLength(1));
    expect(recovered.first.id, 'orphan1');
    expect(recovered.first.state, RecordingLifecycleState.recovered);
    expect(recovered.first.sizeBytes, greaterThan(0));
    expect(recovered.first.sha256, isNotNull);
    expect(recovered.first.durationMs, isNotNull);

    final stored = await db.getLocalRecording('orphan1');
    expect(stored!.state, RecordingLifecycleState.recovered);
    expect(stored.sizeBytes, recovered.first.sizeBytes);
  });

  test('leaves already-complete recordings untouched', () async {
    await store.beginRecording('done1');
    await store.appendChunk('done1', Uint8List.fromList(List.filled(50, 1)));
    final result = await store.finalizeRecording('done1');
    await db.saveLocalRecording(LocalRecordingState(
      id: 'done1',
      state: RecordingLifecycleState.complete,
      sizeBytes: result.sizeBytes,
      sha256: result.sha256Hex,
      durationMs: result.durationMs,
    ));

    final recovered = await recovery.recoverIncompleteRecordings();

    expect(recovered, isEmpty);
    final stored = await db.getLocalRecording('done1');
    expect(stored!.state, RecordingLifecycleState.complete);
  });

  test('drops the bookkeeping row for a "recording" entry with no bytes',
      () async {
    await db.saveLocalRecording(LocalRecordingState(
      id: 'ghost1',
      state: RecordingLifecycleState.recording,
    ));

    final recovered = await recovery.recoverIncompleteRecordings();

    expect(recovered, isEmpty);
    expect(await db.getLocalRecording('ghost1'), isNull);
  });
}
