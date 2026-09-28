import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:idb_shim/idb_browser.dart';
import 'package:web/web.dart' as web;

import 'recording_file_store.dart';
import 'wav.dart';

RecordingFileStore createRecordingFileStore() => WebRecordingFileStore();

const String _dbName = 'relationship_manager_recordings';
const String _chunksStoreName = 'chunks';
const String _keySeparator = '::';

String _chunkKey(String id, int seq) =>
    '$id$_keySeparator${seq.toString().padLeft(9, '0')}';

/// Web [RecordingFileStore]: each recording is stored as an ordered series
/// of raw-PCM chunk records in IndexedDB, one record per [appendChunk] call
/// - so every chunk is durably persisted (survives a closed tab/crash) the
/// moment it arrives, without ever rewriting previously-written bytes.
///
/// The WAV header is never actually stored: it's cheap to compute from the
/// total chunk length, so it's synthesized on demand whenever the full file
/// is requested ([readBytes], [openReadStream], [finalizeRecording]). This
/// keeps [appendChunk] O(1) regardless of how long the recording gets,
/// which matters for the up-to-2-hour maximum recording length.
class WebRecordingFileStore implements RecordingFileStore {
  /// Overridable for tests (e.g. idb_shim's in-memory factory). Defaults to
  /// the real browser IndexedDB factory.
  final IdbFactory? _factoryOverride;

  WebRecordingFileStore({IdbFactory? factory}) : _factoryOverride = factory;

  Database? _db;
  final Map<String, int> _nextSeq = {};

  Future<Database> _open() async {
    final cached = _db;
    if (cached != null) return cached;
    final factory = _factoryOverride ?? idbFactoryBrowser;
    final db = await factory.open(
      _dbName,
      version: 1,
      onUpgradeNeeded: (event) {
        final database = event.database;
        if (!database.objectStoreNames.contains(_chunksStoreName)) {
          database.createObjectStore(_chunksStoreName);
        }
      },
    );
    _db = db;
    return db;
  }

  KeyRange _rangeFor(String id) =>
      KeyRange.bound('$id$_keySeparator', '$id$_keySeparator￿');

  Future<List<Uint8List>> _orderedChunks(String id) async {
    final db = await _open();
    final txn = db.transaction(_chunksStoreName, idbModeReadOnly);
    final values = await txn.objectStore(_chunksStoreName).getAll(_rangeFor(id));
    await txn.completed;
    // getAllKeys/getAll return records ordered by key, and our zero-padded
    // sequence numbers sort the same lexicographically as numerically.
    return values.cast<Uint8List>();
  }

  @override
  Future<void> beginRecording(String id,
      {WavFormat format = WavFormat.standard}) async {
    _nextSeq[id] = 0;
  }

  @override
  Future<void> appendChunk(String id, Uint8List pcmChunk) async {
    final db = await _open();
    final seq = _nextSeq[id] ?? 0;
    _nextSeq[id] = seq + 1;
    final txn = db.transaction(_chunksStoreName, idbModeReadWrite);
    await txn.objectStore(_chunksStoreName).put(pcmChunk, _chunkKey(id, seq));
    await txn.completed;
  }

  Future<Uint8List> _assembleWithHeader(String id, {WavFormat? format}) async {
    final chunks = await _orderedChunks(id);
    if (chunks.isEmpty) {
      throw StateError('No recording found for "$id"');
    }
    final dataLength = chunks.fold<int>(0, (sum, c) => sum + c.length);
    final builder =
        BytesBuilder(copy: false)
          ..add(WavHeader.build(
              dataLength: dataLength, format: format ?? WavFormat.standard));
    for (final chunk in chunks) {
      builder.add(chunk);
    }
    return builder.toBytes();
  }

  @override
  Future<RecordingFinalizeResult> finalizeRecording(String id,
      {WavFormat format = WavFormat.standard}) async {
    final chunks = await _orderedChunks(id);
    if (chunks.isEmpty) {
      throw StateError('No recording found for "$id"');
    }
    final dataLength = chunks.fold<int>(0, (sum, c) => sum + c.length);
    final header = WavHeader.build(dataLength: dataLength, format: format);
    return hashWavStream(
      Stream.fromIterable([header, ...chunks]),
      dataLength: dataLength,
      format: format,
    );
  }

  @override
  Future<Uint8List> readBytes(String id) => _assembleWithHeader(id);

  @override
  Stream<List<int>> openReadStream(String id) async* {
    yield await _assembleWithHeader(id);
  }

  @override
  Future<int> size(String id) async {
    final chunks = await _orderedChunks(id);
    if (chunks.isEmpty) throw StateError('No recording found for "$id"');
    return wavHeaderLength + chunks.fold<int>(0, (sum, c) => sum + c.length);
  }

  @override
  Future<bool> exists(String id) async {
    final chunks = await _orderedChunks(id);
    return chunks.isNotEmpty;
  }

  @override
  Future<void> delete(String id) async {
    _nextSeq.remove(id);
    final db = await _open();
    final txn = db.transaction(_chunksStoreName, idbModeReadWrite);
    final store = txn.objectStore(_chunksStoreName);
    final keys = await store.getAllKeys(_rangeFor(id));
    for (final key in keys) {
      await store.delete(key);
    }
    await txn.completed;
  }

  /// Builds a `blob:` object URL straight from the stored chunks (plus a
  /// synthesized header), never assembling a base64 `data:` URI - see
  /// [RecordingFileStore.openPlaybackSource]'s doc comment for why that
  /// matters for long recordings. Each chunk becomes its own [BlobPart] so
  /// the bytes are never even concatenated into one Dart buffer here; the
  /// browser assembles them lazily.
  @override
  Future<PlaybackSource> openPlaybackSource(String id) async {
    final chunks = await _orderedChunks(id);
    if (chunks.isEmpty) throw StateError('No recording found for "$id"');
    final dataLength = chunks.fold<int>(0, (sum, c) => sum + c.length);
    final header = WavHeader.build(dataLength: dataLength, format: WavFormat.standard);

    final parts = <JSAny>[header.toJS, for (final chunk in chunks) chunk.toJS];
    final blob = web.Blob(parts.toJS, web.BlobPropertyBag(type: 'audio/wav'));
    final url = web.URL.createObjectURL(blob);
    return PlaybackSource.objectUrl(url, () => web.URL.revokeObjectURL(url));
  }

  @override
  Future<String?> filePathIfAvailable(String id) async =>
      null; // IndexedDB-backed - no real file exists to point to.

  @override
  Future<List<String>> listIds() async {
    final db = await _open();
    final txn = db.transaction(_chunksStoreName, idbModeReadOnly);
    final keys = await txn.objectStore(_chunksStoreName).getAllKeys();
    await txn.completed;
    final ids = <String>{};
    for (final key in keys) {
      final k = key as String;
      final sepIndex = k.lastIndexOf(_keySeparator);
      if (sepIndex > 0) ids.add(k.substring(0, sepIndex));
    }
    return ids.toList();
  }
}
