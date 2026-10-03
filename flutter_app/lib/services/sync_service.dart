import 'dart:convert';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:http/http.dart' as http;
import '../models/models.dart';
import 'auth_service.dart';
import 'database_service.dart';
import 'encryption_service.dart';
import 'recording_file_store.dart';
import 'wav.dart';
import '../backup/database_backup_adapter.dart';
import '../backup/backup_format.dart';

class SyncService extends ChangeNotifier {
  final DatabaseService _db;
  final AuthService _auth;
  final EncryptionService _encryption = EncryptionService();
  final RecordingFileStore _recordings;

  // v1: immutable SHA-qualified IDs, fixed 1 MiB plaintext chunks, each
  // independently authenticated by EncryptionService's v1 AEAD envelope.
  // The encrypted story attachment authenticates total WAV size and SHA.
  static const _recordingBlobType = 'recording_chunk_v1';
  static const _recordingChunkBytes = 1024 * 1024;

  /// Injectable so tests can intercept the direct-to-storage blob PUT/GET
  /// calls (these go straight to a presigned S3-style URL, not through
  /// AuthService, so they need their own client to mock). Defaults to a
  /// plain client, so production behaviour is unchanged.
  final http.Client _http;

  bool _isSyncing = false;
  int _encryptionRevision = 0;
  int _syncRevision = 0;
  String? _lastError;
  DateTime? _lastSyncTime;

  /// True when the user is signed in but the encryption key hasn't been
  /// derived yet (e.g. right after an app restart, before they've
  /// re-entered their password) - see the class doc comment. While this is
  /// true, sync is skipped entirely rather than ever risking an
  /// unencrypted upload.
  String? _encryptionUserId;
  String? _encryptionSalt;
  bool _needsEncryptionPassword = false;
  bool get needsEncryptionPassword => _needsEncryptionPassword;

  SyncService(this._db, this._auth,
      {http.Client? httpClient, RecordingFileStore? recordingFileStore})
      : _http = httpClient ?? http.Client(),
        _recordings = recordingFileStore ?? createRecordingFileStore();

  bool get isSyncing => _isSyncing;

  /// True whenever sync can't run because the user isn't signed in (e.g.
  /// they chose "Continue without account"). syncOnOpen/syncOnClose already
  /// no-op in that case; this just gives the UI something to show instead
  /// of silence.
  bool get needsSignIn => !_auth.isAuthenticated;
  String? get lastError => _lastError;
  DateTime? get lastSyncTime => _lastSyncTime;

  // Safe notify that avoids calling during build
  void _safeNotifyListeners() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      notifyListeners();
    });
  }

  String get _currentEncryptionSalt =>
      _auth.encryptionSalt ?? _auth.userId ?? 'default-salt';

  bool get _keyMatchesAccount =>
      _auth.isAuthenticated &&
      _encryption.isInitialized &&
      _encryptionUserId == _auth.userId &&
      _encryptionSalt == _currentEncryptionSalt;

  // Initialize encryption with user's password
  void initializeEncryption(String password) {
    final salt = _currentEncryptionSalt;
    _encryption.initializeWithPassword(password, salt);
    _encryptionUserId = _auth.userId;
    _encryptionSalt = salt;
    _encryptionRevision++;
    _needsEncryptionPassword = false;
    _safeNotifyListeners();
  }

  /// Guard shared by [syncOnOpen] and [syncOnClose]: sync only ever runs
  /// with a working encryption key. Data is encrypted on this device before
  /// it is ever written to a blob that leaves it (see _uploadPersonBlob and
  /// friends), so if the key isn't available yet - most commonly right
  /// after an app restart, when the token was restored from storage but the
  /// user hasn't re-entered their password this session - sync must be
  /// skipped rather than either uploading plaintext or failing to decrypt
  /// what it downloads. [needsEncryptionPassword] exposes this so the UI
  /// can prompt for the password instead of the sync just silently doing
  /// nothing forever.
  bool _requireEncryptionOrSkip() {
    if (_keyMatchesAccount) {
      _needsEncryptionPassword = false;
      return true;
    }
    // Once a different identity is observed, switching back also needs unlock.
    _encryptionUserId = _encryptionSalt = null;
    _needsEncryptionPassword = true;
    _safeNotifyListeners();
    return false;
  }

  void _checkSyncSession() {
    if (!_keyMatchesAccount || _syncRevision != _encryptionRevision) {
      if (!_keyMatchesAccount) _requireEncryptionOrSkip();
      throw StateError('Account or encryption changed during sync');
    }
  }

  Future<http.Response> _syncPost(String path, Map<String, dynamic> body) {
    _checkSyncSession();
    return _auth.authenticatedPost(path, body);
  }

  Future<http.Response> _syncGet(String path) {
    _checkSyncSession();
    return _auth.authenticatedGet(path);
  }

  void _checkResponse(http.Response response, String operation) {
    _checkSyncSession();
    if (response.statusCode != 200) {
      throw StateError('Sync $operation failed (${response.statusCode})');
    }
  }

  // Sync on app open
  Future<void> syncOnOpen({bool forceFull = false}) async {
    if (!_auth.isAuthenticated || _isSyncing) return;
    if (!_requireEncryptionOrSkip()) return;

    _isSyncing = true;
    _syncRevision = _encryptionRevision;
    _lastError = null;
    _safeNotifyListeners();

    try {
      // Get local sync index
      final localIndex = forceFull
          ? SyncIndex(lastSyncTimestamp: 0)
          : await _db.getSyncIndex() ?? SyncIndex();

      // Fetch remote updates
      final response = await _syncPost('/api/sync/updates', {
        'lastSyncVersion': localIndex.lastSyncTimestamp,
      });

      _checkResponse(response, 'updates');
      final data = jsonDecode(response.body);
      final entries =
          (data['entries'] as List).map((e) => _SyncEntry.fromJson(e)).toList();

      // Download and apply each updated blob
      for (final entry in entries) {
        await _downloadAndApplyBlob(entry);
      }

      // Update local sync index
      localIndex.lastSyncTimestamp = data['latestVersion'];
      localIndex.updatedAt = DateTime.now();
      _checkSyncSession();
      await _db.saveSyncIndex(localIndex);
      _checkSyncSession();

      _lastSyncTime = DateTime.now();
    } catch (e) {
      _lastError = e.toString();
      debugPrint('Sync on open error: $e');
    } finally {
      _isSyncing = false;
      _safeNotifyListeners();
    }
  }

  // Sync on app close - upload pending changes
  Future<void> syncOnClose() async {
    if (!_auth.isAuthenticated || _isSyncing) return;
    if (!_requireEncryptionOrSkip()) return;

    _isSyncing = true;
    _syncRevision = _encryptionRevision;
    _lastError = null;
    _safeNotifyListeners();

    try {
      final pendingChanges = await _db.getPendingChanges();
      if (pendingChanges.isEmpty) return;

      // Group changes by entity type for efficient blob creation
      final personChanges =
          pendingChanges.where((c) => c.entityType == 'person').toList();
      final placeChanges =
          pendingChanges.where((c) => c.entityType == 'place').toList();
      final objectChanges =
          pendingChanges.where((c) => c.entityType == 'object').toList();
      final eventChanges =
          pendingChanges.where((c) => c.entityType == 'event').toList();
      final connectionChanges =
          pendingChanges.where((c) => c.entityType == 'connection').toList();

      final syncedIds = <String>[];

      // Upload person blobs
      for (final change in personChanges) {
        if (await _uploadPersonBlob(change.entityId)) {
          syncedIds.add(change.id);
        }
      }

      // Upload place blobs
      for (final change in placeChanges) {
        if (await _uploadPlaceBlob(change.entityId)) {
          syncedIds.add(change.id);
        }
      }

      // Upload object blobs
      for (final change in objectChanges) {
        if (await _uploadObjectBlob(change.entityId)) {
          syncedIds.add(change.id);
        }
      }

      // Upload connection blobs
      for (final change in connectionChanges) {
        if (await _uploadConnectionBlob(change.entityId)) {
          syncedIds.add(change.id);
        }
      }

      // Group events by month and upload month blobs
      final eventMonths = eventChanges.map((c) {
        final event = Event.fromJson(c.data);
        return event.monthKey;
      }).toSet();

      for (final monthKey in eventMonths) {
        if (await _uploadEventMonthBlob(monthKey)) {
          syncedIds.addAll(eventChanges.where((c) {
            final event = Event.fromJson(c.data);
            return event.monthKey == monthKey;
          }).map((c) => c.id));
        }
      }

      // Upload sync index
      if (!await _uploadSyncIndex()) return;

      // Mark changes as synced
      _checkSyncSession();
      await _db.markChangesSynced(syncedIds);
      _checkSyncSession();
      await _db.clearSyncedChanges();
      _checkSyncSession();

      if (_lastError == null) _lastSyncTime = DateTime.now();
    } catch (e) {
      _lastError = e.toString();
      debugPrint('Sync on close error: $e');
    } finally {
      _isSyncing = false;
      _safeNotifyListeners();
    }
  }

  Future<bool> _uploadPersonBlob(String personId) async {
    try {
      final person = await _db.getPerson(personId);
      if (person == null) return false;

      final jsonData = jsonEncode(person.toJson());
      // _requireEncryptionOrSkip() guarantees this is always initialized
      // before any of these upload helpers run - see its doc comment for
      // why data must never fall back to being uploaded as plain jsonData.
      final encryptedData = _encryption.encryptString(jsonData);
      final checksum = _encryption.calculateChecksum(jsonData);

      // Get upload URL
      final uploadResponse = await _syncPost('/api/sync/upload', {
        'blobType': 'person',
        'blobId': personId,
        'checksum': checksum,
        'expectedVersion': 0,
      });

      _checkResponse(uploadResponse, 'upload URL');

      final uploadData = jsonDecode(uploadResponse.body);
      final uploadUrl = uploadData['uploadUrl'];
      final s3Key = uploadData['s3Key'];

      // Upload to S3
      final s3Response = await _http.put(
        Uri.parse(uploadUrl),
        headers: {'Content-Type': 'application/octet-stream'},
        body: utf8.encode(encryptedData),
      );

      _checkResponse(s3Response, 'blob upload');

      // Commit upload
      final commitResponse = await _syncPost('/api/sync/commit', {
        'blobType': 'person',
        'blobId': personId,
        's3Key': s3Key,
        'checksum': checksum,
        'size': encryptedData.length,
        'isDeleted': person.isDeleted,
      });

      _checkResponse(commitResponse, 'commit');
      return true;
    } catch (e) {
      _lastError = e.toString();
      debugPrint('Upload person blob error: $e');
      return false;
    }
  }

  Future<bool> _uploadPlaceBlob(String placeId) async {
    try {
      final place = await _db.getPlace(placeId);
      if (place == null) return false;

      final jsonData = jsonEncode(place.toJson());
      // _requireEncryptionOrSkip() guarantees this is always initialized
      // before any of these upload helpers run - see its doc comment for
      // why data must never fall back to being uploaded as plain jsonData.
      final encryptedData = _encryption.encryptString(jsonData);
      final checksum = _encryption.calculateChecksum(jsonData);

      final uploadResponse = await _syncPost('/api/sync/upload', {
        'blobType': 'place',
        'blobId': placeId,
        'checksum': checksum,
        'expectedVersion': 0,
      });

      _checkResponse(uploadResponse, 'upload URL');

      final uploadData = jsonDecode(uploadResponse.body);
      final uploadUrl = uploadData['uploadUrl'];
      final s3Key = uploadData['s3Key'];

      final s3Response = await _http.put(
        Uri.parse(uploadUrl),
        headers: {'Content-Type': 'application/octet-stream'},
        body: utf8.encode(encryptedData),
      );

      _checkResponse(s3Response, 'blob upload');

      final commitResponse = await _syncPost('/api/sync/commit', {
        'blobType': 'place',
        'blobId': placeId,
        's3Key': s3Key,
        'checksum': checksum,
        'size': encryptedData.length,
        'isDeleted': place.isDeleted,
      });

      _checkResponse(commitResponse, 'commit');
      return true;
    } catch (e) {
      _lastError = e.toString();
      debugPrint('Upload place blob error: $e');
      return false;
    }
  }

  Future<bool> _uploadObjectBlob(String objectId) async {
    try {
      final object = await _db.getObject(objectId);
      if (object == null) return false;

      final jsonData = jsonEncode(object.toJson());
      // _requireEncryptionOrSkip() guarantees this is always initialized
      // before any of these upload helpers run - see its doc comment for
      // why data must never fall back to being uploaded as plain jsonData.
      final encryptedData = _encryption.encryptString(jsonData);
      final checksum = _encryption.calculateChecksum(jsonData);

      final uploadResponse = await _syncPost('/api/sync/upload', {
        'blobType': 'object',
        'blobId': objectId,
        'checksum': checksum,
        'expectedVersion': 0,
      });

      _checkResponse(uploadResponse, 'upload URL');

      final uploadData = jsonDecode(uploadResponse.body);
      final uploadUrl = uploadData['uploadUrl'];
      final s3Key = uploadData['s3Key'];

      final s3Response = await _http.put(
        Uri.parse(uploadUrl),
        headers: {'Content-Type': 'application/octet-stream'},
        body: utf8.encode(encryptedData),
      );

      _checkResponse(s3Response, 'blob upload');

      final commitResponse = await _syncPost('/api/sync/commit', {
        'blobType': 'object',
        'blobId': objectId,
        's3Key': s3Key,
        'checksum': checksum,
        'size': encryptedData.length,
        'isDeleted': object.isDeleted,
      });

      _checkResponse(commitResponse, 'commit');
      return true;
    } catch (e) {
      _lastError = e.toString();
      debugPrint('Upload object blob error: $e');
      return false;
    }
  }

  Future<bool> _uploadConnectionBlob(String connectionId) async {
    try {
      final connection = await _db.getConnection(connectionId);
      if (connection == null) return false;

      final jsonData = jsonEncode(connection.toJson());
      // _requireEncryptionOrSkip() guarantees this is always initialized
      // before any of these upload helpers run - see its doc comment for
      // why data must never fall back to being uploaded as plain jsonData.
      final encryptedData = _encryption.encryptString(jsonData);
      final checksum = _encryption.calculateChecksum(jsonData);

      final uploadResponse = await _syncPost('/api/sync/upload', {
        'blobType': 'connection',
        'blobId': connectionId,
        'checksum': checksum,
        'expectedVersion': 0,
      });

      _checkResponse(uploadResponse, 'upload URL');

      final uploadData = jsonDecode(uploadResponse.body);
      final uploadUrl = uploadData['uploadUrl'];
      final s3Key = uploadData['s3Key'];

      final s3Response = await _http.put(
        Uri.parse(uploadUrl),
        headers: {'Content-Type': 'application/octet-stream'},
        body: utf8.encode(encryptedData),
      );

      _checkResponse(s3Response, 'blob upload');

      final commitResponse = await _syncPost('/api/sync/commit', {
        'blobType': 'connection',
        'blobId': connectionId,
        's3Key': s3Key,
        'checksum': checksum,
        'size': encryptedData.length,
        'isDeleted': connection.isDeleted,
      });

      _checkResponse(commitResponse, 'commit');
      return true;
    } catch (e) {
      _lastError = e.toString();
      debugPrint('Upload connection blob error: $e');
      return false;
    }
  }

  Future<bool> _uploadEventMonthBlob(String monthKey) async {
    try {
      final events =
          await _db.getEvents(monthKey: monthKey, includeDeleted: true);
      final recordings = events
          .expand((event) => event.files)
          .where((file) => file.isRecording)
          .toList();
      final committedChunks = <String, Map<String, dynamic>>{};
      if (recordings.isNotEmpty) {
        final response = await _syncGet('/api/sync/all');
        _checkResponse(response, 'recording metadata');
        for (final entry in jsonDecode(response.body) as List) {
          if (entry['blobType'] == _recordingBlobType) {
            committedChunks[entry['blobId'] as String] =
                Map<String, dynamic>.from(entry as Map);
          }
        }
      }
      for (final file in recordings) {
        await _uploadRecording(file, committedChunks);
      }
      final monthlyEvents = MonthlyEvents(monthKey: monthKey, events: events);

      final jsonData = jsonEncode(monthlyEvents.toJson());
      // _requireEncryptionOrSkip() guarantees this is always initialized
      // before any of these upload helpers run - see its doc comment for
      // why data must never fall back to being uploaded as plain jsonData.
      final encryptedData = _encryption.encryptString(jsonData);
      final checksum = _encryption.calculateChecksum(jsonData);

      final uploadResponse = await _syncPost('/api/sync/upload', {
        'blobType': 'event_month',
        'blobId': monthKey,
        'checksum': checksum,
        'expectedVersion': 0,
      });

      _checkResponse(uploadResponse, 'upload URL');

      final uploadData = jsonDecode(uploadResponse.body);
      final uploadUrl = uploadData['uploadUrl'];
      final s3Key = uploadData['s3Key'];

      final s3Response = await _http.put(
        Uri.parse(uploadUrl),
        headers: {'Content-Type': 'application/octet-stream'},
        body: utf8.encode(encryptedData),
      );

      _checkResponse(s3Response, 'blob upload');

      final commitResponse = await _syncPost('/api/sync/commit', {
        'blobType': 'event_month',
        'blobId': monthKey,
        's3Key': s3Key,
        'checksum': checksum,
        'size': encryptedData.length,
        'isDeleted': false,
      });

      _checkResponse(commitResponse, 'commit');
      return true;
    } catch (e) {
      _lastError = e.toString();
      debugPrint('Upload event month blob error: $e');
      return false;
    }
  }

  Future<bool> _uploadSyncIndex() async {
    try {
      final index = await _db.getSyncIndex() ?? SyncIndex();
      final jsonData = jsonEncode(index.toJson());
      // _requireEncryptionOrSkip() guarantees this is always initialized
      // before any of these upload helpers run - see its doc comment for
      // why data must never fall back to being uploaded as plain jsonData.
      final encryptedData = _encryption.encryptString(jsonData);
      final checksum = _encryption.calculateChecksum(jsonData);

      final uploadResponse = await _syncPost('/api/sync/upload', {
        'blobType': 'index',
        'blobId': 'main',
        'checksum': checksum,
        'expectedVersion': 0,
      });

      _checkResponse(uploadResponse, 'upload URL');

      final uploadData = jsonDecode(uploadResponse.body);
      final uploadUrl = uploadData['uploadUrl'];
      final s3Key = uploadData['s3Key'];

      final s3Response = await _http.put(
        Uri.parse(uploadUrl),
        headers: {'Content-Type': 'application/octet-stream'},
        body: utf8.encode(encryptedData),
      );

      _checkResponse(s3Response, 'blob upload');

      final commitResponse = await _syncPost('/api/sync/commit', {
        'blobType': 'index',
        'blobId': 'main',
        's3Key': s3Key,
        'checksum': checksum,
        'size': encryptedData.length,
        'isDeleted': false,
      });

      _checkResponse(commitResponse, 'commit');
      return true;
    } catch (e) {
      _lastError = e.toString();
      debugPrint('Upload sync index error: $e');
      return false;
    }
  }

  void _validateRecordingMetadata(AttachedFile file) {
    if (!isSafeRecordingId(file.id) ||
        file.size <= wavHeaderLength ||
        file.size > BackupSafetyLimits.maxRecordingBytes ||
        file.size % WavFormat.standard.blockAlign != 0 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(file.sha256 ?? '')) {
      throw FormatException('Invalid recording metadata: ${file.id}');
    }
  }

  String _recordingChunkId(AttachedFile file, int index) =>
      '${file.id}_${file.sha256}_$index';

  // Coalesce small source chunks without ever reading a whole recording.
  Stream<Uint8List> _recordingChunks(String id) async* {
    var buffer = Uint8List(_recordingChunkBytes);
    var used = 0;
    await for (final source in _recordings.openReadStream(id)) {
      var offset = 0;
      while (offset < source.length) {
        final count = (source.length - offset).clamp(0, buffer.length - used);
        buffer.setRange(used, used + count, source, offset);
        used += count;
        offset += count;
        if (used == buffer.length) {
          yield buffer;
          buffer = Uint8List(_recordingChunkBytes);
          used = 0;
        }
      }
    }
    if (used > 0) yield Uint8List.sublistView(buffer, 0, used);
  }

  void _validateWavHeader(AttachedFile file, List<int> bytes) {
    final expected = WavHeader.build(dataLength: file.size - wavHeaderLength);
    if (bytes.length < wavHeaderLength ||
        !listEquals(bytes.sublist(0, wavHeaderLength), expected)) {
      throw FormatException('Invalid WAV header: ${file.id}');
    }
  }

  Future<void> _verifyLocalRecording(AttachedFile file) async {
    _validateRecordingMetadata(file);
    if (!await _recordings.exists(file.id)) {
      throw StateError('Recording is missing on this device: ${file.id}');
    }
    final info = await hashWavStream(_recordings.openReadStream(file.id),
        dataLength: file.size - wavHeaderLength);
    if (info.sizeBytes != file.size || info.sha256Hex != file.sha256) {
      throw StateError('Recording size/checksum conflict: ${file.id}');
    }
    _validateWavHeader(file, await _recordingChunks(file.id).first);
  }

  Future<void> _uploadRecording(AttachedFile file,
      Map<String, Map<String, dynamic>> committedChunks) async {
    await _verifyLocalRecording(file);
    var index = 0;
    await for (final chunk in _recordingChunks(file.id)) {
      final blobId = _recordingChunkId(file, index++);
      final committed = committedChunks[blobId];
      // IDs authenticate the full WAV SHA; committed size checks the exact
      // v1 envelope length. Reuse current-user chunks when only story text changes.
      if (committed != null &&
          committed['isDeleted'] != true &&
          committed['size'] == chunk.length + 35) {
        continue;
      }
      final encrypted = _encryption.encryptBytes(chunk);
      final upload = await _syncPost('/api/sync/upload', {
        'blobType': _recordingBlobType,
        'blobId': blobId,
        'checksum': file.sha256,
        'expectedVersion': 0,
      });
      _checkResponse(upload, 'recording upload URL');
      final data = jsonDecode(upload.body);
      final put = await _http.put(Uri.parse(data['uploadUrl']),
          headers: {'Content-Type': 'application/octet-stream'},
          body: encrypted);
      _checkResponse(put, 'recording upload');
      final commit = await _syncPost('/api/sync/commit', {
        'blobType': _recordingBlobType,
        'blobId': blobId,
        's3Key': data['s3Key'],
        'checksum': file.sha256,
        'size': encrypted.length,
        'isDeleted': false,
      });
      _checkResponse(commit, 'recording commit');
    }
  }

  Future<void> _downloadRecording(AttachedFile file) async {
    _checkSyncSession();
    _validateRecordingMetadata(file);
    if (await _recordings.exists(file.id)) {
      await _verifyLocalRecording(file);
      return;
    }
    final stagingId = const Uuid().v4();
    _checkSyncSession();
    await _recordings.beginRecording(stagingId);
    try {
      for (var index = 0; index * _recordingChunkBytes < file.size; index++) {
        final response = await _syncGet(
            '/api/sync/download/$_recordingBlobType/${_recordingChunkId(file, index)}');
        _checkResponse(response, 'recording download URL');
        final download = await _http.send(http.Request(
            'GET', Uri.parse(jsonDecode(response.body)['downloadUrl'])));
        _checkSyncSession();
        if (download.statusCode != 200) {
          throw StateError(
              'Recording download failed (${download.statusCode})');
        }
        final expectedSize = (file.size - index * _recordingChunkBytes)
            .clamp(0, _recordingChunkBytes);
        final encrypted = BytesBuilder(copy: false);
        await for (final bytes in download.stream) {
          // v1 envelope adds seven prefix bytes, a 12-byte nonce and 16-byte tag.
          if (encrypted.length + bytes.length > expectedSize + 35) {
            throw const FormatException('Oversized encrypted recording chunk');
          }
          encrypted.add(bytes);
        }
        _checkSyncSession();
        final payload = encrypted.takeBytes();
        if (payload.length != expectedSize + 35 ||
            utf8.decode(payload.sublist(0, 7), allowMalformed: true) !=
                'con:v1:') {
          throw const FormatException('Invalid authenticated recording chunk');
        }
        final plain = _encryption.decryptBytes(payload);
        if (plain.length != expectedSize) {
          throw const FormatException('Invalid recording chunk length');
        }
        if (index == 0) _validateWavHeader(file, plain);
        await _recordings.appendChunk(stagingId,
            index == 0 ? Uint8List.sublistView(plain, wavHeaderLength) : plain);
      }
      _checkSyncSession();
      final result = await _recordings.finalizeRecording(stagingId);
      if (result.sizeBytes != file.size || result.sha256Hex != file.sha256) {
        throw StateError('Recording checksum mismatch: ${file.id}');
      }
      // The staging ID is a new transient import, never a user's original.
      // Original bytes are written only after all chunks/header/hash verify.
      // Another tab/restore may have saved this ID while the network awaited.
      if (await _recordings.exists(file.id)) {
        await _verifyLocalRecording(file);
        return;
      }
      final adapter = DatabaseBackupAdapter(
          databaseService: _db, recordingStore: _recordings);
      _checkSyncSession();
      try {
        await adapter.storeVerifiedRecordingStream(
            file.id, _recordings.openReadStream(stagingId),
            sha256Hex: result.sha256Hex);
      } catch (_) {
        await _recordings.delete(file.id); // incomplete new import only
        rethrow;
      }
    } finally {
      await _recordings.delete(stagingId);
    }
  }

  Future<void> _downloadAndApplyBlob(_SyncEntry entry) async {
    _checkSyncSession();
    // Audio is fetched only through its authenticated story metadata, so
    // orphan chunks from an interrupted upload do not become local recordings.
    if (entry.blobType == _recordingBlobType) return;
    if (entry.isDeleted) {
      switch (entry.blobType) {
        case 'person':
          final person = await _db.getPerson(entry.blobId);
          if (person != null) {
            _checkSyncSession();
            await _db.savePerson(person.copyWith(isDeleted: true),
                recordPendingChange: false);
          }
          break;
        case 'place':
          final place = await _db.getPlace(entry.blobId);
          if (place != null) {
            _checkSyncSession();
            await _db.savePlace(place.copyWith(isDeleted: true),
                recordPendingChange: false);
          }
          break;
        case 'object':
          final object = await _db.getObject(entry.blobId);
          if (object != null) {
            _checkSyncSession();
            await _db.saveObject(object.copyWith(isDeleted: true),
                recordPendingChange: false);
          }
          break;
        case 'connection':
          final connection = await _db.getConnection(entry.blobId);
          if (connection != null) {
            _checkSyncSession();
            await _db.saveConnection(connection.copyWith(isDeleted: true),
                recordPendingChange: false);
          }
          break;
        case 'event_month':
          final events = await _db.getEvents(monthKey: entry.blobId);
          _checkSyncSession();
          await _db.bulkSaveEvents(
              events.map((event) => event.copyWith(isDeleted: true)).toList());
          break;
        case 'index':
          break; // A deleted remote index does not delete this device's cursor.
        default:
          throw UnsupportedError(
              'Unsupported sync blob type: ${entry.blobType}');
      }
      return;
    }
    final response = await _syncGet(
        '/api/sync/download/${entry.blobType}/${entry.blobId}');

    _checkResponse(response, 'download');

    final data = jsonDecode(response.body);
    final downloadUrl = data['downloadUrl'];

    final blobResponse = await _http.get(Uri.parse(downloadUrl));
    _checkResponse(blobResponse, 'blob download');

    final encryptedData = blobResponse.body;
    // Same guarantee as above: encryption is always initialized here.
    final jsonData = _encryption.decryptString(encryptedData);

    final parsedData = jsonDecode(jsonData);

    switch (entry.blobType) {
      // recordPendingChange: false on every case below - this data just
      // came FROM the backend, so re-queuing it as a pending change would
      // upload it straight back next sync (see DatabaseService.savePerson's
      // doc comment).
      case 'person':
        final person = Person.fromJson(parsedData);
        await _db.savePerson(person, recordPendingChange: false);
        break;
      case 'place':
        final place = Place.fromJson(parsedData);
        await _db.savePlace(place, recordPendingChange: false);
        break;
      case 'object':
        final object = EventObject.fromJson(parsedData);
        await _db.saveObject(object, recordPendingChange: false);
        break;
      case 'connection':
        final connection = Connection.fromJson(parsedData);
        await _db.saveConnection(connection, recordPendingChange: false);
        break;
      case 'event_month':
        final monthlyEvents = MonthlyEvents.fromJson(parsedData);
        for (final event in monthlyEvents.events) {
          for (final file in event.files.where((file) => file.isRecording)) {
            await _downloadRecording(file);
          }
        }
        _checkSyncSession();
        await _db.bulkSaveEvents(monthlyEvents.events);
        for (final event in monthlyEvents.events) {
          for (final file in event.files.where((file) => file.isRecording)) {
            final recording = await _db.getLocalRecording(file.id);
            if (recording != null) {
              _checkSyncSession();
              await _db
                  .saveLocalRecording(recording.copyWith(eventId: event.id));
            }
          }
        }
        break;
      case 'index':
        final index = SyncIndex.fromJson(parsedData);
        // A remote device's cursor cannot acknowledge this device's downloads.
        index.lastSyncTimestamp =
            (await _db.getSyncIndex())?.lastSyncTimestamp ?? 0;
        _checkSyncSession();
        await _db.saveSyncIndex(index);
        break;
      default:
        throw UnsupportedError('Unsupported sync blob type: ${entry.blobType}');
    }
  }

  // Force full sync
  Future<void> forceFullSync() async {
    if (!_auth.isAuthenticated || _isSyncing) return;
    if (!_requireEncryptionOrSkip()) return;

    final revision = _encryptionRevision;
    // Request all updates without changing the persisted cursor until success.
    await syncOnOpen(forceFull: true);
    if (_lastError == null && _keyMatchesAccount && revision == _encryptionRevision) {
      await syncOnClose();
    }
  }

  // Alias for fullSync (used by settings screen)
  Future<void> fullSync() async {
    await forceFullSync();
  }
}

// Internal sync entry class
class _SyncEntry {
  final String blobType;
  final String blobId;
  final String s3Key;
  final int version;
  final bool isDeleted;

  _SyncEntry({
    required this.blobType,
    required this.blobId,
    required this.s3Key,
    required this.version,
    required this.isDeleted,
  });

  factory _SyncEntry.fromJson(Map<String, dynamic> json) => _SyncEntry(
        blobType: json['blobType'],
        blobId: json['blobId'],
        s3Key: json['s3Key'],
        version: json['version'],
        isDeleted: json['isDeleted'] ?? false,
      );
}
