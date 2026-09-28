import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'recording_file_store.dart';
import 'wav.dart';

RecordingFileStore createRecordingFileStore() => NativeRecordingFileStore();

/// Native (Android/iOS/desktop) [RecordingFileStore]: each recording is a
/// plain WAV file on disk under `<app documents>/recordings/`.
///
/// Crash safety: while a recording is in progress its bytes live at
/// `<id>.wav.tmp`, flushed to disk after every appended chunk. Only
/// [finalizeRecording] rewrites the WAV header in place (audio bytes are
/// never touched) and renames the file to its final `<id>.wav` name. So a
/// crash or kill mid-recording leaves a `.tmp` file with everything
/// captured so far, ready to be repaired by calling [finalizeRecording] on
/// it again - which is exactly what start-up recovery does.
class NativeRecordingFileStore implements RecordingFileStore {
  /// Overridable so tests can point this at a temporary directory instead
  /// of the real app documents directory. When left null, it's resolved
  /// lazily via [getApplicationDocumentsDirectory] the first time it's
  /// needed - production code never has to pass this.
  final Directory? _baseDirectoryOverride;
  Directory? _resolvedDirectory;

  NativeRecordingFileStore({Directory? baseDirectory})
      : _baseDirectoryOverride = baseDirectory;

  final Map<String, RandomAccessFile> _openWriters = {};

  Future<Directory> _recordingsDir() async {
    final cached = _resolvedDirectory;
    if (cached != null) return cached;
    final base =
        _baseDirectoryOverride ?? await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'recordings'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _resolvedDirectory = dir;
    return dir;
  }

  Future<File> _finalFile(String id) async =>
      File(p.join((await _recordingsDir()).path, '$id.wav'));

  Future<File> _tempFile(String id) async =>
      File(p.join((await _recordingsDir()).path, '$id.wav.tmp'));

  /// Whichever of the temp/final file currently holds this recording,
  /// preferring the finalized one. Null if neither exists.
  Future<File?> _resolveExisting(String id) async {
    final finalFile = await _finalFile(id);
    if (await finalFile.exists()) return finalFile;
    final tempFile = await _tempFile(id);
    if (await tempFile.exists()) return tempFile;
    return null;
  }

  @override
  Future<void> beginRecording(String id,
      {WavFormat format = WavFormat.standard}) async {
    final file = await _tempFile(id);
    final raf = await file.open(mode: FileMode.writeOnly);
    await raf.writeFrom(WavHeader.build(dataLength: 0, format: format));
    await raf.flush();
    _openWriters[id] = raf;
  }

  @override
  Future<void> appendChunk(String id, Uint8List pcmChunk) async {
    final raf = _openWriters[id];
    if (raf == null) {
      throw StateError('appendChunk("$id") called without beginRecording');
    }
    await raf.writeFrom(pcmChunk);
    // Persist immediately: this is what makes the recording survive a
    // crash beyond just what happened to already reach the OS write cache.
    await raf.flush();
  }

  @override
  Future<RecordingFinalizeResult> finalizeRecording(String id,
      {WavFormat format = WavFormat.standard}) async {
    // Close any open writer for this id first so every byte is flushed.
    final openRaf = _openWriters.remove(id);
    if (openRaf != null) {
      await openRaf.flush();
      await openRaf.close();
    }

    final tempFile = await _tempFile(id);
    final finalFile = await _finalFile(id);
    final workingFile = (await tempFile.exists()) ? tempFile : finalFile;
    if (!await workingFile.exists()) {
      throw StateError('No recording found for "$id"');
    }

    final totalLength = await workingFile.length();
    final dataLength =
        totalLength > wavHeaderLength ? totalLength - wavHeaderLength : 0;

    // Rewrite just the 44-byte header in place; the audio bytes after it
    // are never touched or re-encoded.
    final raf = await workingFile.open(mode: FileMode.writeOnlyAppend);
    await raf.setPosition(0);
    await raf.writeFrom(WavHeader.build(dataLength: dataLength, format: format));
    await raf.flush();
    await raf.close();

    final result = await hashWavStream(
      workingFile.openRead(),
      dataLength: dataLength,
      format: format,
    );

    if (workingFile.path != finalFile.path) {
      await workingFile.rename(finalFile.path);
    }

    return result;
  }

  @override
  Future<Uint8List> readBytes(String id) async {
    final file = await _resolveExisting(id);
    if (file == null) throw StateError('No recording found for "$id"');
    return file.readAsBytes();
  }

  @override
  Stream<List<int>> openReadStream(String id) async* {
    final file = await _resolveExisting(id);
    if (file == null) throw StateError('No recording found for "$id"');
    yield* file.openRead();
  }

  @override
  Future<int> size(String id) async {
    final file = await _resolveExisting(id);
    if (file == null) throw StateError('No recording found for "$id"');
    return file.length();
  }

  @override
  Future<bool> exists(String id) async => (await _resolveExisting(id)) != null;

  @override
  Future<void> delete(String id) async {
    final openRaf = _openWriters.remove(id);
    if (openRaf != null) {
      await openRaf.close();
    }
    final finalFile = await _finalFile(id);
    final tempFile = await _tempFile(id);
    if (await finalFile.exists()) await finalFile.delete();
    if (await tempFile.exists()) await tempFile.delete();
  }

  @override
  Future<PlaybackSource> openPlaybackSource(String id) async {
    final file = await _resolveExisting(id);
    if (file == null) throw StateError('No recording found for "$id"');
    return PlaybackSource.file(file.path);
  }

  @override
  Future<String?> filePathIfAvailable(String id) async {
    final file = await _resolveExisting(id);
    return file?.path;
  }

  @override
  Future<List<String>> listIds() async {
    final dir = await _recordingsDir();
    if (!await dir.exists()) return [];
    final ids = <String>{};
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.endsWith('.wav.tmp')) {
        ids.add(name.substring(0, name.length - '.wav.tmp'.length));
      } else if (name.endsWith('.wav')) {
        ids.add(name.substring(0, name.length - '.wav'.length));
      }
    }
    return ids.toList();
  }
}
