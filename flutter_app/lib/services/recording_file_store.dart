import 'dart:typed_data';

import 'recording_file_store_stub.dart'
    if (dart.library.io) 'recording_file_store_native.dart'
    if (dart.library.html) 'recording_file_store_web.dart' as impl;
import 'wav.dart';

export 'wav.dart' show WavFormat, RecordingFinalizeResult, wavHeaderLength;

/// Where the app keeps the *original* audio for a recorded story, so a
/// relative can always be played back verbatim - not just read as a
/// transcript.
///
/// Two implementations exist behind this interface, picked automatically
/// via conditional import so `dart:io` is never referenced from code that
/// gets compiled for web:
/// - native (Android/iOS/desktop): plain WAV files under the app's
///   documents directory, see recording_file_store_native.dart.
/// - web: IndexedDB, see recording_file_store_web.dart.
///
/// Format: every recording is WAV, PCM 16-bit, mono, 16 kHz (see
/// [WavFormat.standard]) - the transcription backend's required input, and
/// a format that can be appended to incrementally and played back
/// anywhere. **The original recording is never overwritten or re-encoded**
/// once [finalizeRecording] has run; finalizing only patches the 44-byte
/// header in place to record the real length.
///
/// Crash safety: implementations persist appended chunks as they arrive
/// (not only when the recording finishes), so audio recorded before a
/// crash or a closed tab is never lost. A recording that never reached
/// [finalizeRecording] can be repaired by calling [finalizeRecording] on it
/// again later - it rewrites the header from whatever bytes actually exist,
/// which is exactly what a start-up recovery pass needs (see
/// RecordingRecoveryService).
///
/// ### Deletion rule
/// A recording's bytes belong to exactly one event and must only be
/// deleted from this store by [delete] after **explicit user confirmation**
/// of that specific deletion - either "delete this recording" on the
/// recording itself, or emptying a soft-deleted event that still owns it.
/// Soft-deleting an event (`Event.isDeleted = true`) must NEVER by itself
/// call [delete]: the audio has to stay recoverable for as long as the
/// soft-deleted event could still be restored. See
/// `DatabaseService.deleteRecordingPermanently` for the one sanctioned
/// call site.
abstract class RecordingFileStore {
  /// Starts a new recording with the given [id] (normally a fresh UUID).
  /// Must be called once before any [appendChunk] call for that id.
  Future<void> beginRecording(String id, {WavFormat format = WavFormat.standard});

  /// Appends raw PCM bytes (no WAV header) to a recording started with
  /// [beginRecording]. Implementations persist this immediately so it
  /// survives a crash.
  Future<void> appendChunk(String id, Uint8List pcmChunk);

  /// Finalizes a recording: (re)writes the WAV header to match the real
  /// amount of PCM data captured, and computes its size/SHA-256/duration.
  /// Safe to call on a recording that was already finalized (idempotent),
  /// and is exactly how an interrupted ("recording" state) recording gets
  /// repaired after a crash.
  Future<RecordingFinalizeResult> finalizeRecording(String id,
      {WavFormat format = WavFormat.standard});

  /// Reads a whole recording's bytes (header included).
  Future<Uint8List> readBytes(String id);

  /// Opens a recording's bytes (header included) as a stream, for
  /// playback or upload without holding the whole file in memory.
  Stream<List<int>> openReadStream(String id);

  /// Total size in bytes (header included).
  Future<int> size(String id);

  Future<bool> exists(String id);

  /// Permanently deletes a recording's bytes. See the deletion rule above -
  /// this must only be reached after explicit user confirmation.
  Future<void> delete(String id);

  /// Every recording id currently stored, finished or not.
  Future<List<String>> listIds();

  /// Opens a source a player can hand straight to the platform's media
  /// stack, without ever materializing the whole file as a base64 `data:`
  /// URI (a one-hour recording is ~115 MB of WAV, which becomes a ~150 MB
  /// string - too slow/large for some platforms/browsers to handle as a
  /// URI). On native this is the local file path; on web it's a `blob:`
  /// object URL built from the stored chunks.
  ///
  /// Callers MUST call [PlaybackSource.release] once they're done with it
  /// (e.g. from `State.dispose`) - on web this revokes the object URL so
  /// its memory can be freed; on native it's a no-op.
  Future<PlaybackSource> openPlaybackSource(String id);
}

/// Where a [RecordingPlayer] should read a recording's audio from. Exactly
/// one of [filePath] (native) or [objectUrl] (web) is set - see
/// [RecordingFileStore.openPlaybackSource].
class PlaybackSource {
  final String? filePath;
  final String? objectUrl;
  final void Function()? _onRelease;

  const PlaybackSource.file(String path)
      : filePath = path,
        objectUrl = null,
        _onRelease = null;

  PlaybackSource.objectUrl(String url, void Function() onRelease)
      : filePath = null,
        objectUrl = url,
        _onRelease = onRelease;

  /// Releases any resources this source holds - on web, revokes the
  /// `blob:` object URL. Safe to call more than once; safe to call on a
  /// native (file-backed) source, where it's a no-op.
  void release() => _onRelease?.call();
}

/// Creates the [RecordingFileStore] implementation for the current
/// platform (native file storage, or IndexedDB on web).
RecordingFileStore createRecordingFileStore() => impl.createRecordingFileStore();
