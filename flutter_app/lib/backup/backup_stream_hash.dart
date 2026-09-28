/// Chunked SHA-256/CRC-32 helpers shared by BackupWriter and BackupRestorer
/// so a recording never has to be fully resident in memory just to compute
/// its checksum - see the peak-memory regression tests in
/// test/backup/large_recording_test.dart for what this is actually
/// defending against (a two-hour recording is roughly 228 MB).
library;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

/// How many bytes at a time every chunked read in this file processes - far
/// more than one WAV frame, far less than even a short recording, so peak
/// memory per recording stays a rounding error next to a multi-hundred-MB
/// one.
const int backupStreamChunkBytes = 1024 * 1024; // 1 MiB

/// Minimal [Sink] that remembers the one [Digest] a hash's chunked
/// conversion produces when closed. package:crypto doesn't export a
/// ready-made one for this (its own `DigestSink` lives under its private
/// `src/`) - lib/services/wav.dart already defines the identical few lines
/// privately for the same reason; this is that same shape, reused here so
/// the writer/restorer don't have to buffer a whole recording just to call
/// `sha256.convert()` on it in one go.
class _DigestCollector implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}

/// The SHA-256 of [stream]'s bytes, read [chunkSize] at a time from
/// position 0 to the end - never the whole stream at once, however long it
/// is. Leaves [stream] rewound to position 0 when done (via
/// [InputStream.reset]), ready to be read again (e.g. for the actual zip
/// write, or - on restore - to be handed to RecordingFileStore chunk by
/// chunk via [chunksOfInputStream]).
String sha256OfInputStream(InputStream stream, {int chunkSize = backupStreamChunkBytes}) {
  stream.reset();
  final collector = _DigestCollector();
  final sink = sha256.startChunkedConversion(collector);
  var remaining = stream.length;
  while (remaining > 0) {
    final take = remaining < chunkSize ? remaining : chunkSize;
    sink.add(stream.readBytes(take).toUint8List());
    remaining -= take;
  }
  sink.close();
  stream.reset();
  return collector.digest!.toString();
}

/// Both the CRC-32 a zip "store" entry's local header needs before any data
/// is written, and the SHA-256 this app's backup manifest records for the
/// same recording - computed in the SAME chunked pass over [stream], so a
/// recording read straight from disk (see BackupWriter) is only read
/// through once for both instead of twice. Leaves [stream] rewound to
/// position 0 when done.
({int crc32, String sha256Hex}) hashInputStreamForZipEntry(
  InputStream stream, {
  int chunkSize = backupStreamChunkBytes,
}) {
  stream.reset();
  final collector = _DigestCollector();
  final sink = sha256.startChunkedConversion(collector);
  var crc = 0;
  var remaining = stream.length;
  while (remaining > 0) {
    final take = remaining < chunkSize ? remaining : chunkSize;
    final bytes = stream.readBytes(take).toUint8List();
    crc = getCrc32(bytes, crc);
    sink.add(bytes);
    remaining -= take;
  }
  sink.close();
  stream.reset();
  return (crc32: crc, sha256Hex: collector.digest!.toString());
}

/// Reads [stream] from its CURRENT position to the end, yielding
/// [chunkSize]-sized chunks as an async stream - the shape
/// RecordingFileStore.appendChunk-based consumers expect (see
/// BackupRestorer/DatabaseBackupAdapter's streaming restore). Does not
/// reset [stream] first: [sha256OfInputStream]/[hashInputStreamForZipEntry]
/// already rewind when they're done, so a caller that just hashed a stream
/// with either of those can chain straight into this one; a caller starting
/// fresh is responsible for [stream] already being at the position it wants
/// read from.
Stream<List<int>> chunksOfInputStream(InputStream stream,
    {int chunkSize = backupStreamChunkBytes}) async* {
  var remaining = stream.length;
  while (remaining > 0) {
    final take = remaining < chunkSize ? remaining : chunkSize;
    yield stream.readBytes(take).toUint8List();
    remaining -= take;
  }
}
