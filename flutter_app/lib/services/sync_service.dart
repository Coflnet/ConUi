import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:http/http.dart' as http;
import '../models/models.dart';
import 'auth_service.dart';
import 'database_service.dart';
import 'encryption_service.dart';

class SyncService extends ChangeNotifier {
  final DatabaseService _db;
  final AuthService _auth;
  final EncryptionService _encryption = EncryptionService();

  /// Injectable so tests can intercept the direct-to-storage blob PUT/GET
  /// calls (these go straight to a presigned S3-style URL, not through
  /// AuthService, so they need their own client to mock). Defaults to a
  /// plain client, so production behaviour is unchanged.
  final http.Client _http;

  bool _isSyncing = false;
  String? _lastError;
  DateTime? _lastSyncTime;

  /// True when the user is signed in but the encryption key hasn't been
  /// derived yet (e.g. right after an app restart, before they've
  /// re-entered their password) - see the class doc comment. While this is
  /// true, sync is skipped entirely rather than ever risking an
  /// unencrypted upload.
  bool _needsEncryptionPassword = false;
  bool get needsEncryptionPassword => _needsEncryptionPassword;

  SyncService(this._db, this._auth, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

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

  // Initialize encryption with user's password
  void initializeEncryption(String password) {
    final salt = _auth.encryptionSalt ?? _auth.userId ?? 'default-salt';
    _encryption.initializeWithPassword(password, salt);
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
    if (_encryption.isInitialized) {
      _needsEncryptionPassword = false;
      return true;
    }
    _needsEncryptionPassword = true;
    _safeNotifyListeners();
    return false;
  }

  // Sync on app open
  Future<void> syncOnOpen() async {
    if (!_auth.isAuthenticated || _isSyncing) return;
    if (!_requireEncryptionOrSkip()) return;

    _isSyncing = true;
    _lastError = null;
    _safeNotifyListeners();

    try {
      // Get local sync index
      final localIndex = await _db.getSyncIndex() ?? SyncIndex();

      // Fetch remote updates
      final response = await _auth.authenticatedPost('/api/sync/updates', {
        'lastSyncVersion': localIndex.lastSyncTimestamp,
      });

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final entries = (data['entries'] as List)
            .map((e) => _SyncEntry.fromJson(e))
            .toList();

        // Download and apply each updated blob
        for (final entry in entries) {
          await _downloadAndApplyBlob(entry);
        }

        // Update local sync index
        localIndex.lastSyncTimestamp = data['latestVersion'];
        localIndex.updatedAt = DateTime.now();
        await _db.saveSyncIndex(localIndex);
      }

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
      await _uploadSyncIndex();

      // Mark changes as synced
      await _db.markChangesSynced(syncedIds);
      await _db.clearSyncedChanges();

      _lastSyncTime = DateTime.now();
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
      final uploadResponse = await _auth.authenticatedPost('/api/sync/upload', {
        'blobType': 'person',
        'blobId': personId,
        'checksum': checksum,
        'expectedVersion': 0,
      });

      if (uploadResponse.statusCode != 200) return false;

      final uploadData = jsonDecode(uploadResponse.body);
      final uploadUrl = uploadData['uploadUrl'];
      final s3Key = uploadData['s3Key'];

      // Upload to S3
      final s3Response = await _http.put(
        Uri.parse(uploadUrl),
        headers: {'Content-Type': 'application/octet-stream'},
        body: utf8.encode(encryptedData),
      );

      if (s3Response.statusCode != 200) return false;

      // Commit upload
      await _auth.authenticatedPost('/api/sync/commit', {
        'blobType': 'person',
        'blobId': personId,
        's3Key': s3Key,
        'checksum': checksum,
        'size': encryptedData.length,
        'isDeleted': person.isDeleted,
      });

      return true;
    } catch (e) {
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

      final uploadResponse = await _auth.authenticatedPost('/api/sync/upload', {
        'blobType': 'place',
        'blobId': placeId,
        'checksum': checksum,
        'expectedVersion': 0,
      });

      if (uploadResponse.statusCode != 200) return false;

      final uploadData = jsonDecode(uploadResponse.body);
      final uploadUrl = uploadData['uploadUrl'];
      final s3Key = uploadData['s3Key'];

      final s3Response = await _http.put(
        Uri.parse(uploadUrl),
        headers: {'Content-Type': 'application/octet-stream'},
        body: utf8.encode(encryptedData),
      );

      if (s3Response.statusCode != 200) return false;

      await _auth.authenticatedPost('/api/sync/commit', {
        'blobType': 'place',
        'blobId': placeId,
        's3Key': s3Key,
        'checksum': checksum,
        'size': encryptedData.length,
        'isDeleted': place.isDeleted,
      });

      return true;
    } catch (e) {
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

      final uploadResponse = await _auth.authenticatedPost('/api/sync/upload', {
        'blobType': 'object',
        'blobId': objectId,
        'checksum': checksum,
        'expectedVersion': 0,
      });

      if (uploadResponse.statusCode != 200) return false;

      final uploadData = jsonDecode(uploadResponse.body);
      final uploadUrl = uploadData['uploadUrl'];
      final s3Key = uploadData['s3Key'];

      final s3Response = await _http.put(
        Uri.parse(uploadUrl),
        headers: {'Content-Type': 'application/octet-stream'},
        body: utf8.encode(encryptedData),
      );

      if (s3Response.statusCode != 200) return false;

      await _auth.authenticatedPost('/api/sync/commit', {
        'blobType': 'object',
        'blobId': objectId,
        's3Key': s3Key,
        'checksum': checksum,
        'size': encryptedData.length,
        'isDeleted': object.isDeleted,
      });

      return true;
    } catch (e) {
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

      final uploadResponse = await _auth.authenticatedPost('/api/sync/upload', {
        'blobType': 'connection',
        'blobId': connectionId,
        'checksum': checksum,
        'expectedVersion': 0,
      });

      if (uploadResponse.statusCode != 200) return false;

      final uploadData = jsonDecode(uploadResponse.body);
      final uploadUrl = uploadData['uploadUrl'];
      final s3Key = uploadData['s3Key'];

      final s3Response = await _http.put(
        Uri.parse(uploadUrl),
        headers: {'Content-Type': 'application/octet-stream'},
        body: utf8.encode(encryptedData),
      );

      if (s3Response.statusCode != 200) return false;

      await _auth.authenticatedPost('/api/sync/commit', {
        'blobType': 'connection',
        'blobId': connectionId,
        's3Key': s3Key,
        'checksum': checksum,
        'size': encryptedData.length,
        'isDeleted': connection.isDeleted,
      });

      return true;
    } catch (e) {
      debugPrint('Upload connection blob error: $e');
      return false;
    }
  }

  Future<bool> _uploadEventMonthBlob(String monthKey) async {
    try {
      final events =
          await _db.getEvents(monthKey: monthKey, includeDeleted: true);
      final monthlyEvents = MonthlyEvents(monthKey: monthKey, events: events);

      final jsonData = jsonEncode(monthlyEvents.toJson());
      // _requireEncryptionOrSkip() guarantees this is always initialized
      // before any of these upload helpers run - see its doc comment for
      // why data must never fall back to being uploaded as plain jsonData.
      final encryptedData = _encryption.encryptString(jsonData);
      final checksum = _encryption.calculateChecksum(jsonData);

      final uploadResponse = await _auth.authenticatedPost('/api/sync/upload', {
        'blobType': 'event_month',
        'blobId': monthKey,
        'checksum': checksum,
        'expectedVersion': 0,
      });

      if (uploadResponse.statusCode != 200) return false;

      final uploadData = jsonDecode(uploadResponse.body);
      final uploadUrl = uploadData['uploadUrl'];
      final s3Key = uploadData['s3Key'];

      final s3Response = await _http.put(
        Uri.parse(uploadUrl),
        headers: {'Content-Type': 'application/octet-stream'},
        body: utf8.encode(encryptedData),
      );

      if (s3Response.statusCode != 200) return false;

      await _auth.authenticatedPost('/api/sync/commit', {
        'blobType': 'event_month',
        'blobId': monthKey,
        's3Key': s3Key,
        'checksum': checksum,
        'size': encryptedData.length,
        'isDeleted': false,
      });

      return true;
    } catch (e) {
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

      final uploadResponse = await _auth.authenticatedPost('/api/sync/upload', {
        'blobType': 'index',
        'blobId': 'main',
        'checksum': checksum,
        'expectedVersion': 0,
      });

      if (uploadResponse.statusCode != 200) return false;

      final uploadData = jsonDecode(uploadResponse.body);
      final uploadUrl = uploadData['uploadUrl'];
      final s3Key = uploadData['s3Key'];

      final s3Response = await _http.put(
        Uri.parse(uploadUrl),
        headers: {'Content-Type': 'application/octet-stream'},
        body: utf8.encode(encryptedData),
      );

      if (s3Response.statusCode != 200) return false;

      await _auth.authenticatedPost('/api/sync/commit', {
        'blobType': 'index',
        'blobId': 'main',
        's3Key': s3Key,
        'checksum': checksum,
        'size': encryptedData.length,
        'isDeleted': false,
      });

      return true;
    } catch (e) {
      debugPrint('Upload sync index error: $e');
      return false;
    }
  }

  Future<void> _downloadAndApplyBlob(_SyncEntry entry) async {
    try {
      final response = await _auth.authenticatedGet(
          '/api/sync/download/${entry.blobType}/${entry.blobId}');

      if (response.statusCode != 200) return;

      final data = jsonDecode(response.body);
      final downloadUrl = data['downloadUrl'];

      final blobResponse = await _http.get(Uri.parse(downloadUrl));
      if (blobResponse.statusCode != 200) return;

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
          await _db.bulkSaveEvents(monthlyEvents.events);
          break;
        case 'index':
          final index = SyncIndex.fromJson(parsedData);
          await _db.saveSyncIndex(index);
          break;
      }
    } catch (e) {
      debugPrint('Download blob error: $e');
    }
  }

  // Force full sync
  Future<void> forceFullSync() async {
    if (!_auth.isAuthenticated || _isSyncing) return;

    // Reset sync index to force full download
    await _db.saveSyncIndex(SyncIndex(lastSyncTimestamp: 0));
    await syncOnOpen();
    await syncOnClose();
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
