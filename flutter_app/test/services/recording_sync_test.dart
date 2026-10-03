// Real production KDF and multi-chunk AEAD run concurrently with builds in CI.
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/services/auth_service.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/encryption_service.dart';
import 'package:relationship_manager/services/recording_file_store_native.dart';
import 'package:relationship_manager/services/sync_service.dart';
import '../support/test_database.dart';

class _StreamingStore extends NativeRecordingFileStore {
  _StreamingStore(Directory directory) : super(baseDirectory: directory);
  @override
  Future<Uint8List> readBytes(String id) =>
      throw StateError('Whole reads are forbidden');
}

class _Backend {
  final blobs = <String, List<int>>{};
  final entries = <String, Map<String, dynamic>>{};
  String? failure;
  int version = 0;
  int largestAudioUpload = 0;
  int audioUploads = 0;
  Future<void> Function()? onAudioDownload;

  late final api = MockClient((request) async {
    if (request.url.path == '/api/sync/all') {
      return http.Response(jsonEncode(entries.values.toList()),
          failure == 'metadata' ? 503 : 200);
    }
    if (request.url.path == '/api/sync/updates') {
      final since = jsonDecode(request.body)['lastSyncVersion'] as int;
      return http.Response(
          jsonEncode({
            'entries': entries.values
                .where((e) => (e['version'] as int) > since)
                .toList(),
            'latestVersion': version
          }),
          200);
    }
    if (request.url.path.startsWith('/api/sync/download/')) {
      final key = request.url.path.substring('/api/sync/download/'.length);
      if (!entries.containsKey(key) ||
          failure == 'download' && key.startsWith('recording_chunk_v1/')) {
        return http.Response('{}', 503);
      }
      return http.Response(
          jsonEncode({'downloadUrl': 'https://storage.test/$key'}), 200);
    }
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final key = "${body['blobType']}/${body['blobId']}";
    if (request.url.path == '/api/sync/upload') {
      return http.Response(
          jsonEncode({'uploadUrl': 'https://storage.test/$key', 's3Key': key}),
          200);
    }
    if (failure == 'commit' && key.startsWith('recording_chunk_v1/')) {
      return http.Response('{}', 503);
    }
    entries[key] = {...body, 'version': ++version};
    return http.Response('{}', 200);
  });

  late final storage = MockClient((request) async {
    final key = request.url.path.substring(1);
    final audio = key.startsWith('recording_chunk_v1/');
    if (request.method == 'PUT') {
      if (audio) {
        audioUploads++;
        largestAudioUpload = largestAudioUpload < request.bodyBytes.length
            ? request.bodyBytes.length
            : largestAudioUpload;
        if (failure == 'upload') return http.Response('', 503);
      }
      blobs[key] = List<int>.from(request.bodyBytes);
      return http.Response('', 200);
    }
    if (audio && onAudioDownload != null) {
      final action = onAudioDownload!;
      onAudioDownload = null;
      await action();
    }
    if (audio && failure == 'storage') return http.Response('', 503);
    final bytes = List<int>.from(blobs[key]!);
    if (audio && failure == 'tamper') bytes[bytes.length - 1] ^= 1;
    if (audio && failure == 'oversize') bytes.add(0);
    return http.Response.bytes(bytes, 200);
  });
}

Future<SyncService> _sync(
    DatabaseService db, _StreamingStore store, _Backend backend) async {
  final auth = AuthService(httpClient: backend.api);
  await auth.initialize();
  return SyncService(db, auth,
      httpClient: backend.storage, recordingFileStore: store)
    ..initializeEncryption('password');
}

Future<AttachedFile> _record(_StreamingStore store,
    {int pcmSize = 128, String id = 'recording'}) async {
  await store.beginRecording(id);
  await store.appendChunk(
      id, Uint8List.fromList(List.generate(pcmSize, (i) => i % 251)));
  final result = await store.finalizeRecording(id);
  return AttachedFile(
      id: id,
      fileName: '$id.wav',
      filePath: 'local/$id.wav',
      mimeType: 'audio/wav',
      size: result.sizeBytes,
      durationMs: result.durationMs,
      sha256: result.sha256Hex,
      kind: AttachedFile.kindRecording);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory senderDir;
  late Directory receiverDir;
  late _StreamingStore sender;
  late _StreamingStore receiver;
  late DatabaseService senderDb;
  late DatabaseService receiverDb;
  late _Backend backend;
  late SyncService senderSync;
  late SyncService receiverSync;

  setUp(() async {
    SharedPreferences.setMockInitialValues(
        {'auth_token': 'fake.token.value', 'user_id': 'u1'});
    senderDir = Directory.systemTemp.createTempSync('con-sync-sender');
    receiverDir = Directory.systemTemp.createTempSync('con-sync-receiver');
    sender = _StreamingStore(senderDir);
    receiver = _StreamingStore(receiverDir);
    senderDb = createTestDatabaseService();
    receiverDb = createTestDatabaseService();
    await senderDb.initialize();
    await receiverDb.initialize();
    backend = _Backend();
    senderSync = await _sync(senderDb, sender, backend);
    receiverSync = await _sync(receiverDb, receiver, backend);
  });

  tearDown(() {
    senderDir.deleteSync(recursive: true);
    receiverDir.deleteSync(recursive: true);
  });

  test(
      'story and multi-chunk original audio roundtrip byte-identically without whole reads',
      () async {
    final file = await _record(sender, pcmSize: 1024 * 1024 + 128);
    final story =
        Event(title: 'Original story', dateTime: DateTime(1952), files: [file]);
    await senderDb.saveEvent(story);
    await senderSync.syncOnClose();
    expect(senderSync.lastError, isNull);
    expect(await senderDb.getPendingChanges(), isEmpty);
    expect(
        backend.entries.keys
            .where((key) => key.startsWith('recording_chunk_v1/')),
        hasLength(2));
    expect(backend.largestAudioUpload, lessThanOrEqualTo(1024 * 1024 + 35));
    await receiverSync.syncOnOpen();
    expect(receiverSync.lastError, isNull);
    expect((await receiverDb.getEvent(story.id))!.title, story.title);
    final original =
        await File((await sender.filePathIfAvailable(file.id))!).readAsBytes();
    final synced = await File((await receiver.filePathIfAvailable(file.id))!)
        .readAsBytes();
    expect(synced, orderedEquals(original));
    expect((await receiverDb.getLocalRecording(file.id))!.eventId, story.id);
    expect(await receiverDb.getPendingChanges(), isEmpty);
    await receiverSync.forceFullSync();
    expect(receiverSync.lastError, isNull);
    expect(
        await File((await receiver.filePathIfAvailable(file.id))!)
            .readAsBytes(),
        orderedEquals(original));
  });

  for (final failure in [
    'missing',
    'checksum',
    'metadata',
    'upload',
    'commit'
  ]) {
    test(
        '$failure audio upload keeps story pending and does not publish metadata',
        () async {
      final file = await _record(sender);
      if (failure == 'missing') await sender.delete(file.id);
      if (failure == 'checksum') file.sha256 = '0' * 64;
      backend.failure = failure;
      await senderDb.saveEvent(
          Event(title: 'Retry', dateTime: DateTime(1952), files: [file]));
      await senderSync.syncOnClose();
      expect(senderSync.lastError, isNotNull);
      expect(await senderDb.getPendingChanges(), hasLength(1));
      expect(
          backend.entries.keys.where((key) => key.startsWith('event_month/')),
          isEmpty);
      if (failure == 'metadata' || failure == 'upload' || failure == 'commit') {
        backend.failure = null;
        await senderSync.syncOnClose();
        expect(senderSync.lastError, isNull);
        expect(await senderDb.getPendingChanges(), isEmpty);
      }
    });
  }

  for (final failure in ['download', 'storage', 'tamper', 'oversize']) {
    test('$failure audio download keeps cursor and original for retry',
        () async {
      final file = await _record(sender);
      final story = Event(
          title: 'Retry download', dateTime: DateTime(1952), files: [file]);
      await senderDb.saveEvent(story);
      await senderSync.syncOnClose();
      backend.failure = failure;
      await receiverSync.syncOnOpen();
      expect(receiverSync.lastError, isNotNull);
      expect((await receiverDb.getSyncIndex())?.lastSyncTimestamp ?? 0, 0);
      expect(await receiverDb.getEvent(story.id), isNull);
      expect(await receiver.listIds(), isEmpty);
      backend.failure = null;
      await receiverSync.syncOnOpen();
      expect(receiverSync.lastError, isNull);
      expect(await receiver.exists(file.id), isTrue);
      expect(await receiverDb.getEvent(story.id), isNotNull);
    });
  }

  test(
      'conflicting local audio stays byte-identical and remote story is not applied',
      () async {
    final file = await _record(sender);
    final story =
        Event(title: 'Conflict', dateTime: DateTime(1952), files: [file]);
    await senderDb.saveEvent(story);
    await senderSync.syncOnClose();
    await _record(receiver, pcmSize: 256, id: file.id);
    final path = (await receiver.filePathIfAvailable(file.id))!;
    final original = await File(path).readAsBytes();
    await receiverSync.syncOnOpen();
    expect(receiverSync.lastError, contains('conflict'));
    expect(await File(path).readAsBytes(), orderedEquals(original));
    expect(await receiverDb.getEvent(story.id), isNull);
    expect((await receiverDb.getSyncIndex())?.lastSyncTimestamp ?? 0, 0);
  });

  test(
      'editing a story reuses committed immutable audio without another upload',
      () async {
    final file = await _record(sender);
    final story =
        Event(title: 'Original', dateTime: DateTime(1952), files: [file]);
    await senderDb.saveEvent(story);
    await senderSync.syncOnClose();
    expect(backend.audioUploads, 1);
    await senderDb.saveEvent(story.copyWith(title: 'Edited'));
    await senderSync.syncOnClose();
    expect(senderSync.lastError, isNull);
    expect(await senderDb.getPendingChanges(), isEmpty);
    expect(backend.audioUploads, 1);
    final audioKey = backend.entries.keys
        .firstWhere((key) => key.startsWith('recording_chunk_v1/'));
    backend.entries[audioKey]!['size'] = 0;
    await senderDb.saveEvent(story.copyWith(title: 'Edited again'));
    await senderSync.syncOnClose();
    expect(backend.audioUploads, 2,
        reason: 'wrong-sized metadata cannot authorize reuse');
    backend.entries[audioKey]!['isDeleted'] = true;
    await senderDb.saveEvent(story.copyWith(title: 'Edited after deletion'));
    await senderSync.syncOnClose();
    expect(backend.audioUploads, 3,
        reason: 'deleted chunks cannot authorize reuse');
    await receiverSync.syncOnOpen();
    expect(
        (await receiverDb.getEvent(story.id))!.title, 'Edited after deletion');
    expect(await receiver.exists(file.id), isTrue);
  });

  test('original appearing during download is verified and never overwritten',
      () async {
    final file = await _record(sender);
    final story = Event(
        title: 'Concurrent arrival', dateTime: DateTime(1952), files: [file]);
    await senderDb.saveEvent(story);
    await senderSync.syncOnClose();
    Uint8List? original;
    backend.onAudioDownload = () async {
      await _record(receiver, pcmSize: 256, id: file.id);
      original = await File((await receiver.filePathIfAvailable(file.id))!)
          .readAsBytes();
    };
    await receiverSync.syncOnOpen();
    expect(receiverSync.lastError, contains('conflict'));
    expect(
        await File((await receiver.filePathIfAvailable(file.id))!)
            .readAsBytes(),
        orderedEquals(original!));
    expect(await receiver.listIds(), [file.id]);
    expect(await receiverDb.getEvent(story.id), isNull);
    expect((await receiverDb.getSyncIndex())?.lastSyncTimestamp ?? 0, 0);
  });

  test('authenticated malformed WAV and wrong full checksum never import',
      () async {
    final file = await _record(sender);
    final story =
        Event(title: 'Validation', dateTime: DateTime(1952), files: [file]);
    await senderDb.saveEvent(story);
    await senderSync.syncOnClose();
    final encryptor = EncryptionService()
      ..initializeWithPassword('password', 'u1');
    final key = backend.blobs.keys
        .firstWhere((key) => key.startsWith('recording_chunk_v1/'));
    final validEncrypted = backend.blobs[key]!;
    final plain = encryptor.decryptBytes(validEncrypted);
    plain[0] = 0;
    backend.blobs[key] = encryptor.encryptBytes(plain);
    await receiverSync.syncOnOpen();
    expect(receiverSync.lastError, contains('WAV header'));
    expect(await receiver.listIds(), isEmpty);
    plain[0] = 'R'.codeUnitAt(0);
    plain[44] ^= 1;
    backend.blobs[key] = encryptor.encryptBytes(plain);
    await receiverSync.syncOnOpen();
    expect(receiverSync.lastError, contains('checksum mismatch'));
    expect(await receiver.listIds(), isEmpty);
    expect(await receiverDb.getEvent(story.id), isNull);
  });
}
