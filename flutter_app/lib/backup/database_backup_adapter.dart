import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common/sqflite.dart';

import '../models/local_recording_state.dart';
import '../services/database_service.dart';
import '../services/db_migrations.dart';
import '../services/recording_file_store.dart';
import 'backup_entity.dart';
import 'backup_source.dart';

/// Bridges the pure-Dart [BackupDataSource]/[BackupDataSink] interfaces to
/// the real [DatabaseService] and [RecordingFileStore]. This is the only
/// place in lib/backup/ that talks to either of them directly, so
/// BackupWriter/BackupRestorer stay Flutter-free and fast to test; this
/// file is exercised by its own tests against a real (in-memory/temp-dir)
/// database and recording store instead.
///
/// Keeps its footprint on the shared services to the public API they
/// already expose (`DatabaseService.database`, `getLocalRecording`,
/// `RecordingFileStore`'s interface) rather than adding new methods there.
class DatabaseBackupAdapter implements BackupDataSource, BackupDataSink {
  final DatabaseService databaseService;
  final RecordingFileStore recordingStore;

  DatabaseBackupAdapter({required this.databaseService, required this.recordingStore});

  // Keep in sync with pubspec.yaml's `version:` field. Not read from a
  // package_info plugin to avoid a new dependency for one string; see the
  // final report.
  static const String _appVersion = '1.0.0+1';

  @override
  Future<String> appVersion() async => _appVersion;

  @override
  Future<int> schemaVersion() async => latestDbVersion;

  @override
  Stream<BackupEntityRecord> readTable(String table) async* {
    final db = await databaseService.database;
    final rows =
        await db.query(table, columns: ['id', 'data', 'created_at', 'updated_at', 'is_deleted']);
    for (final row in rows) {
      yield BackupEntityRecord(
        table: table,
        id: row['id'] as String,
        data: Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map),
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
        isDeleted: (row['is_deleted'] as int? ?? 0) != 0,
      );
    }
  }

  @override
  Future<List<String>> recordingIdsOnDevice() => recordingStore.listIds();

  @override
  Future<String?> recordingFilePath(String id) => recordingStore.filePathIfAvailable(id);

  @override
  Stream<List<int>> openRecordingStream(String id) => recordingStore.openReadStream(id);

  @override
  Future<DateTime?> existingUpdatedAt(String table, String id) async {
    final db = await databaseService.database;
    final rows =
        await db.query(table, columns: ['updated_at'], where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return DateTime.parse(rows.first['updated_at'] as String);
  }

  @override
  Future<String?> existingRecordingChecksum(String id) async {
    final row = await databaseService.getLocalRecording(id);
    if (row?.sha256 != null) return row!.sha256;
    // Bookkeeping row missing or not yet finalized, but bytes might still
    // be on disk (e.g. a recording captured before this table existed) -
    // fall back to actually hashing them so a real conflict is never
    // mistaken for "nothing here yet".
    if (await recordingStore.exists(id)) {
      final bytes = await recordingStore.readBytes(id);
      return sha256.convert(bytes).toString();
    }
    return null;
  }

  @override
  Future<void> storeVerifiedRecordingStream(String id, Stream<List<int>> wavBytes,
      {required String sha256Hex}) async {
    await recordingStore.beginRecording(id);
    // wavBytes carries the WAV header (see RecordingFileStore's doc
    // comment: appendChunk only ever takes raw PCM), so the first
    // wavHeaderLength bytes - however they happen to be split across
    // chunks - are dropped here rather than requiring the caller to hand
    // over a chunking that respects the header boundary.
    var headerBytesSkipped = 0;
    await for (final chunk in wavBytes) {
      if (headerBytesSkipped < wavHeaderLength) {
        final headerBytesRemaining = wavHeaderLength - headerBytesSkipped;
        if (chunk.length <= headerBytesRemaining) {
          headerBytesSkipped += chunk.length;
          continue;
        }
        final pcmPart = chunk.sublist(headerBytesRemaining);
        headerBytesSkipped = wavHeaderLength;
        if (pcmPart.isNotEmpty) {
          await recordingStore.appendChunk(
              id, pcmPart is Uint8List ? pcmPart : Uint8List.fromList(pcmPart));
        }
      } else {
        await recordingStore.appendChunk(
            id, chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
      }
    }
    final result = await recordingStore.finalizeRecording(id);

    await databaseService.saveLocalRecording(LocalRecordingState(
      id: id,
      state: RecordingLifecycleState.complete,
      sizeBytes: result.sizeBytes,
      sha256: result.sha256Hex,
      durationMs: result.durationMs,
    ));
  }

  @override
  Future<void> applyEntityRestore(List<BackupEntityRecord> entities) async {
    if (entities.isEmpty) return;
    final db = await databaseService.database;

    await db.transaction((txn) async {
      for (final record in entities) {
        final exists =
            (await txn.query(record.table, columns: ['id'], where: 'id = ?', whereArgs: [record.id]))
                .isNotEmpty;

        await txn.insert(record.table, _rowFor(record), conflictAlgorithm: ConflictAlgorithm.replace);

        await txn.insert('pending_changes', {
          'id': '${record.table}_${record.id}_${DateTime.now().millisecondsSinceEpoch}',
          'entity_type': _singularEntityType(record.table),
          'entity_id': record.id,
          'operation': exists ? 'update' : 'create',
          'data': jsonEncode(record.data),
          'created_at': DateTime.now().toIso8601String(),
          'synced': 0,
        });

        if (record.table == 'events') {
          for (final recordingId in _recordingIdsIn(record)) {
            await txn.update(
              'local_recordings',
              {'event_id': record.id},
              where: 'id = ? AND event_id IS NULL',
              whereArgs: [recordingId],
            );
          }
        }
      }
    });

    databaseService.notifyDataRestored();
  }

  Map<String, Object?> _rowFor(BackupEntityRecord record) {
    final base = <String, Object?>{
      'id': record.id,
      'data': jsonEncode(record.data),
      'version': record.updatedAt.millisecondsSinceEpoch,
      'created_at': record.createdAt.toIso8601String(),
      'updated_at': record.updatedAt.toIso8601String(),
      'is_deleted': record.isDeleted ? 1 : 0,
    };
    switch (record.table) {
      case 'connections':
        base['person1_id'] = record.data['person1Id'];
        base['person2_id'] = record.data['person2Id'];
        base['relationship_type'] = record.data['relationshipType'];
        base['origin_event_id'] = record.data['originEventId'];
        break;
      case 'events':
        base['month_key'] = _monthKeyOf(record.data['dateTime'] as String?) ??
            '${record.updatedAt.year}-${record.updatedAt.month.toString().padLeft(2, '0')}';
        break;
    }
    return base;
  }

  String? _monthKeyOf(String? isoDateTime) {
    if (isoDateTime == null) return null;
    final dt = DateTime.tryParse(isoDateTime);
    if (dt == null) return null;
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}';
  }

  String _singularEntityType(String table) {
    // Matches the entity_type strings DatabaseService's own save*() methods
    // already write into pending_changes (see _addPendingChange call
    // sites), so restored changes flow through sync exactly like locally
    // made ones.
    switch (table) {
      case 'persons':
        return 'person';
      case 'connections':
        return 'connection';
      case 'places':
        return 'place';
      case 'events':
        return 'event';
      case 'objects':
        return 'object';
      default:
        return table;
    }
  }

  Iterable<String> _recordingIdsIn(BackupEntityRecord eventRecord) sync* {
    final files = eventRecord.data['files'];
    if (files is! List) return;
    for (final f in files) {
      if (f is Map && f['kind'] == 'recording' && f['id'] is String) {
        yield f['id'] as String;
      }
    }
  }
}
