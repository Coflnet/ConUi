// In-memory fakes for BackupDataSource/BackupDataSink, used throughout
// test/backup/ to exercise BackupWriter/BackupRestorer without touching a
// real database or filesystem - that's what keeps those tests fast, and
// keeps BackupWriter/BackupRestorer honestly "pure Dart" (see their doc
// comments): nothing in this file needs Flutter either.
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:relationship_manager/backup/backup_entity.dart';
import 'package:relationship_manager/backup/backup_source.dart';
import 'package:relationship_manager/services/wav.dart';

/// Builds a complete WAV file (header + PCM) the way RecordingFileStore
/// would, filled with a repeatable, seed-derived byte pattern so tests can
/// tell recordings apart and reproduce them for byte-for-byte comparisons.
Uint8List buildTestWav(int pcmLength, {int seed = 0}) {
  final pcm = Uint8List.fromList(List<int>.generate(pcmLength, (i) => (seed + i) % 256));
  final header = WavHeader.build(dataLength: pcm.length);
  final out = Uint8List(header.length + pcm.length);
  out.setRange(0, header.length, header);
  out.setRange(header.length, out.length, pcm);
  return out;
}

String sha256Of(Uint8List bytes) => sha256.convert(bytes).toString();

/// A minimal `files` JSON entry for an event that references a recording,
/// exactly as AttachedFile.toJson() would write it.
Map<String, dynamic> recordingFileJson(String recordingId,
    {int size = 100, String? sha256Hex}) {
  return {
    'id': recordingId,
    'fileName': '$recordingId.wav',
    'filePath': '$recordingId.wav',
    'mimeType': 'audio/wav',
    'size': size,
    'addedAt': DateTime(2024, 1, 1).toIso8601String(),
    'kind': 'recording',
    if (sha256Hex != null) 'sha256': sha256Hex,
  };
}

BackupEntityRecord makeRecord(
  String table,
  String id, {
  Map<String, dynamic>? data,
  DateTime? createdAt,
  DateTime? updatedAt,
  bool isDeleted = false,
}) {
  final created = createdAt ?? DateTime(2024, 1, 1);
  return BackupEntityRecord(
    table: table,
    id: id,
    data: {'id': id, ...?data},
    createdAt: created,
    updatedAt: updatedAt ?? created,
    isDeleted: isDeleted,
  );
}

class FakeBackupDataSource implements BackupDataSource {
  final Map<String, List<BackupEntityRecord>> tables;
  final Map<String, Uint8List> recordingsOnDevice;

  /// Recordings backed by a REAL file on disk instead of an in-memory
  /// Uint8List - id -> path. Exercises BackupWriter's file-streaming path
  /// (see [BackupDataSource.recordingFilePath]) exactly the way
  /// DatabaseBackupAdapter/NativeRecordingFileStore do, which is what the
  /// peak-memory regression tests in test/backup/large_recording_test.dart
  /// need: a recording backed by [recordingsOnDevice] is already fully in
  /// memory before the writer even sees it, which would make a memory
  /// measurement meaningless.
  final Map<String, String> recordingFilePaths;

  final String appVersionValue;
  final int schemaVersionValue;

  /// Every id ever asked about via [recordingFilePath]/[openRecordingStream],
  /// in call order - lets tests assert recordings are read one at a time
  /// rather than all up front.
  final List<String> readRequests = [];

  FakeBackupDataSource({
    Map<String, List<BackupEntityRecord>>? tables,
    Map<String, Uint8List>? recordingsOnDevice,
    Map<String, String>? recordingFilePaths,
    this.appVersionValue = '1.0.0+1',
    this.schemaVersionValue = 2,
  })  : tables = tables ?? {},
        recordingsOnDevice = recordingsOnDevice ?? {},
        recordingFilePaths = recordingFilePaths ?? {};

  @override
  Future<String> appVersion() async => appVersionValue;

  @override
  Future<int> schemaVersion() async => schemaVersionValue;

  @override
  Stream<BackupEntityRecord> readTable(String table) async* {
    for (final r in tables[table] ?? const <BackupEntityRecord>[]) {
      yield r;
    }
  }

  @override
  Future<List<String>> recordingIdsOnDevice() async =>
      {...recordingsOnDevice.keys, ...recordingFilePaths.keys}.toList();

  @override
  Future<String?> recordingFilePath(String id) async {
    readRequests.add(id);
    return recordingFilePaths[id];
  }

  @override
  Stream<List<int>> openRecordingStream(String id) {
    final bytes = recordingsOnDevice[id];
    if (bytes == null) throw StateError('FakeBackupDataSource: no recording "$id"');
    return Stream.value(bytes);
  }
}

class FakeBackupDataSink implements BackupDataSink {
  /// table -> id -> record currently "in the database".
  final Map<String, Map<String, BackupEntityRecord>> tables = {};

  /// id -> wav bytes currently "on disk".
  final Map<String, Uint8List> recordings = {};

  /// id -> checksum bookkeeping, independent of [recordings] so tests can
  /// simulate a conflicting local recording without needing its real bytes.
  final Map<String, String> recordingChecksums = {};

  final List<List<BackupEntityRecord>> applyEntityRestoreCalls = [];

  /// How many times [storeVerifiedRecording] actually wrote bytes - tests
  /// use this to prove alreadyPresent/conflictKept never call it.
  int storeVerifiedRecordingCalls = 0;

  /// Records "recording:<id>" / "entities" in call order, so tests can
  /// assert every recording is stored before entity data is applied.
  final List<String> callOrder = [];

  /// Seeds a pre-existing local entity, as if it were already in the
  /// database before a restore runs.
  void seedEntity(BackupEntityRecord record) {
    tables.putIfAbsent(record.table, () => {})[record.id] = record;
  }

  /// Seeds a pre-existing local recording (bytes + checksum), as if it were
  /// already on disk before a restore runs.
  void seedRecording(String id, Uint8List wavBytes) {
    recordings[id] = wavBytes;
    recordingChecksums[id] = sha256Of(wavBytes);
  }

  /// Seeds a checksum WITHOUT bytes, to simulate a conflicting recording
  /// whose bytes tests don't need to materialize.
  void seedChecksumOnly(String id, String sha256Hex) {
    recordingChecksums[id] = sha256Hex;
  }

  @override
  Future<DateTime?> existingUpdatedAt(String table, String id) async =>
      tables[table]?[id]?.updatedAt;

  @override
  Future<String?> existingRecordingChecksum(String id) async => recordingChecksums[id];

  @override
  Future<void> storeVerifiedRecordingStream(String id, Stream<List<int>> wavBytes,
      {required String sha256Hex}) async {
    storeVerifiedRecordingCalls++;
    callOrder.add('recording:$id');
    final builder = BytesBuilder(copy: false);
    await for (final chunk in wavBytes) {
      builder.add(chunk);
    }
    recordings[id] = builder.takeBytes();
    recordingChecksums[id] = sha256Hex;
  }

  @override
  Future<void> applyEntityRestore(List<BackupEntityRecord> entities) async {
    callOrder.add('entities');
    applyEntityRestoreCalls.add(entities);
    for (final r in entities) {
      tables.putIfAbsent(r.table, () => {})[r.id] = r;
    }
  }
}
