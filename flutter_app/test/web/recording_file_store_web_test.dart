@TestOn('browser')
@Timeout(Duration(minutes: 2))
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_browser.dart';
import 'package:uuid/uuid.dart';
import 'package:relationship_manager/services/recording_file_store_web.dart';
import 'package:relationship_manager/services/wav.dart';

// Remap only the database name; transactions and storage are real IndexedDB.
class _TestFactory extends IdbFactory {
  final databaseName = 'con-recording-store-test-${const Uuid().v4()}';
  Database? database;

  @override
  Future<Database> open(String dbName,
      {int? version,
      OnUpgradeNeededFunction? onUpgradeNeeded,
      OnBlockedFunction? onBlocked}) async {
    return database = await idbFactoryNative.open(databaseName,
        version: version,
        onUpgradeNeeded: onUpgradeNeeded,
        onBlocked: onBlocked);
  }

  Future<void> cleanup() async {
    database?.close();
    await idbFactoryNative.deleteDatabase(databaseName);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _TestFactory factory;
  setUp(() => factory = _TestFactory());
  tearDown(() => factory.cleanup());
  test('stream, size and finalization preserve WAV with bounded chunk reads',
      () async {
    final store = WebRecordingFileStore(factory: factory);
    await store.beginRecording('original');
    final pcm = Uint8List.fromList(List.generate(65536, (i) => i % 251));
    for (var index = 0; index < 80; index++) {
      await store.appendChunk('original', pcm);
    }
    final result = await store.finalizeRecording('original');
    expect(result.sizeBytes, wavHeaderLength + 80 * pcm.length);
    expect(await store.size('original'), result.sizeBytes);
    var count = 0;
    var total = 0;
    await for (final chunk in store.openReadStream('original')) {
      expect(chunk.length, lessThanOrEqualTo(pcm.length));
      if (count == 0) {
        expect(
            chunk, orderedEquals(WavHeader.build(dataLength: 80 * pcm.length)));
      } else {
        expect(chunk, orderedEquals(pcm));
      }
      count++;
      total += chunk.length;
      // Model a network consumer waiting beyond a transaction's lifetime.
      await Future<void>.delayed(Duration.zero);
    }
    expect(count, 81);
    expect(total, result.sizeBytes);
    final streamed = await hashWavStream(store.openReadStream('original'),
        dataLength: 80 * pcm.length);
    expect(streamed.sha256Hex, result.sha256Hex);
    expect((await store.finalizeRecording('original')).sha256Hex,
        result.sha256Hex);
    final playback = await store.openPlaybackSource('original');
    expect(playback.objectUrl, startsWith('blob:'));
    playback.release();
  });

  test('missing recordings and delete still behave consistently', () async {
    final store = WebRecordingFileStore(factory: factory);
    expect(await store.exists('missing'), isFalse);
    await expectLater(store.size('missing'), throwsStateError);
    await store.beginRecording('recording');
    await store.appendChunk('recording', Uint8List(64));
    expect(await store.exists('recording'), isTrue);
    await store.delete('recording');
    expect(await store.exists('recording'), isFalse);
    expect(await store.listIds(), isEmpty);
  });
}
