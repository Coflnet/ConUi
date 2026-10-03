/// The on-disk shape of a Relationship Manager backup archive, and the sane
/// limits used to defend against a corrupt or hostile archive on restore.
///
/// This file is deliberately free of Flutter and dart:io imports so it -
/// and everything built on top of it in this directory - can be exercised
/// by fast, plain `dart test`-style unit tests. Platform glue (reading the
/// real database, writing real files, picking a save location) lives in
/// backup_service.dart and database_backup_adapter.dart.
library;

/// The only archive format version this code knows how to write and read.
/// A backup declaring any other [BackupManifest.formatVersion] is refused
/// on restore with a clear message - see [BackupRestorer].
const int currentBackupFormatVersion = 1;

/// Every entity table this app backs up and restores, in the order they're
/// written to data.json. Keeping this as the single source of truth means
/// the writer, the restorer and their tests all agree on what "every
/// table" means.
const List<String> backupEntityTables = [
  'persons',
  'connections',
  'places',
  'events',
  'objects',
  'files',
];

/// Fixed names of the entries every backup archive contains. Restoring code
/// looks entries up by exactly these names - never by iterating whatever
/// names happen to be present in an untrusted archive.
class BackupEntryNames {
  static const String manifest = 'manifest.json';
  static const String data = 'data.json';
  static const String readme = 'README.txt';
  static const String recordingsDir = 'recordings';

  /// The archive path for one recording's bytes. [recordingId] must already
  /// have been validated with [isSafeRecordingId] - this is only ever used
  /// to WRITE an archive, never to interpret one, so it's fine for it to
  /// build a path from an id we generated ourselves.
  static String recordingEntry(String recordingId) =>
      '$recordingsDir/$recordingId.wav';
}

/// True when [id] is safe to use as a filename / RecordingFileStore key: the
/// app only ever generates uuid-v4-style ids (see package:uuid), so
/// anything else reaching here - in particular anything that could act as a
/// path segment like `..` or contain a `/` - is either corruption or a
/// hostile archive, and must never be handed to a file store or the
/// database. See the restore hardening rules in backup_restorer.dart.
bool isSafeRecordingId(String id) {
  if (id.isEmpty || id.length > 128) return false;
  return RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id);
}

/// Sane limits enforced while reading an untrusted archive. "Store" mode
/// (used for every recording) means the compressed and uncompressed sizes
/// are always equal, so it isn't possible to build a classic deflate zip
/// bomb out of the recordings/ directory; these limits exist to reject
/// corrupt central-directory metadata and absurd inputs, not to defend
/// against compression amplification there. manifest.json and data.json
/// ARE deflate-compressed, so they get their own, much smaller caps.
class BackupSafetyLimits {
  /// Maximum number of entries a backup archive may contain. Generous for
  /// even a large family archive (recordings + a handful of metadata
  /// entries); guards against an archive engineered to have huge numbers
  /// of entries just to blow up processing time/metadata memory.
  static const int maxEntryCount = 200000;

  /// Maximum allowed uncompressed size of manifest.json.
  static const int maxManifestBytes = 4 * 1024 * 1024; // 4 MB

  /// Maximum allowed uncompressed size of data.json. At roughly 1-2 KB per
  /// story/person/place/object/connection, this comfortably covers tens of
  /// thousands of entities.
  static const int maxDataJsonBytes = 512 * 1024 * 1024; // 512 MB

  /// Maximum allowed uncompressed size of README.txt.
  static const int maxReadmeBytes = 64 * 1024; // 64 KB

  /// Maximum size of a single recording. At ~1.9 MB/minute (mono 16-bit PCM
  /// @16kHz) this covers roughly 43 hours of continuous audio in one file,
  /// far beyond anything this app ever records in one sitting.
  static const int maxRecordingBytes = 5 * 1024 * 1024 * 1024; // 5 GB

  /// Maximum total size of every recording combined, across a whole
  /// restore. A generous multi-device family archive ceiling; well below
  /// what would actually exhaust a phone's storage outright, so restore
  /// fails with a clear message instead of filling the disk.
  static const int maxTotalRecordingBytes = 50 * 1024 * 1024 * 1024; // 50 GB
}
