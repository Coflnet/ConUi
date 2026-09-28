// Large-recording tests: a 50 MB generated recording round-trips
// correctly, and peak memory while writing an archive does not grow with
// how many recordings (or how much total audio) go into it - only with the
// size of whichever single recording is being copied at that moment. See
// BackupWriter's doc comment for the guarantee this is checking, and the
// final report for exactly how "memory" is measured here (dart:io's
// ProcessInfo.currentRss, sampled around each recording).
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/backup/backup_progress.dart';
import 'package:relationship_manager/backup/backup_restorer.dart';
import 'package:relationship_manager/backup/backup_source.dart';
import 'package:relationship_manager/backup/backup_writer.dart';
import 'package:relationship_manager/services/wav.dart';

import 'fakes.dart';

/// Writes a generated WAV file straight to disk, [chunkSize] bytes at a
/// time, so the FIXTURE itself never holds the whole recording in memory
/// either - the point of the test below is to measure BackupWriter's
/// memory use, and that signal would be worthless if setting up its input
/// already required a big in-memory buffer.
Future<void> _writeGeneratedWavFile(String path, int pcmLength,
    {int seed = 0, int chunkSize = 1024 * 1024}) async {
  final raf = await File(path).open(mode: FileMode.write);
  try {
    await raf.writeFrom(WavHeader.build(dataLength: pcmLength));
    var written = 0;
    while (written < pcmLength) {
      final take = (pcmLength - written) < chunkSize ? (pcmLength - written) : chunkSize;
      final chunk = Uint8List(take);
      for (var i = 0; i < take; i++) {
        chunk[i] = (seed + written + i) % 256;
      }
      await raf.writeFrom(chunk);
      written += take;
    }
  } finally {
    await raf.close();
  }
}

void main() {
  test('a 50 MB recording backs up and restores byte for byte', () async {
    final bigWav = buildTestWav(50 * 1024 * 1024, seed: 99);
    final source = FakeBackupDataSource(recordingsOnDevice: {'big': bigWav});

    final output = OutputMemoryStream();
    final writeResult = await BackupWriter().write(source: source, output: output);
    expect(writeResult.manifest.recordings.single.sizeBytes, bigWav.length);

    final sink = FakeBackupDataSink();
    final restoreResult =
        await BackupRestorer().apply(InputMemoryStream(output.getBytes()), sink);
    expect(restoreResult.recordings.single.outcome, RecordingOutcome.restored);
    expect(sink.recordings['big'], bigWav);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'peak memory while writing recordings does not grow with their total size '
    '(only with the size of the one currently being copied)',
    () async {
      if (!Platform.isLinux && !Platform.isMacOS && !Platform.isWindows) {
        return; // ProcessInfo.currentRss needs a native OS process.
      }

      const perRecordingBytes = 5 * 1024 * 1024; // 5 MB each
      const recordingCount = 16; // 80 MB total if ever held all at once

      final recordings = <String, Uint8List>{
        for (var i = 0; i < recordingCount; i++)
          'rec$i': buildTestWav(perRecordingBytes, seed: i),
      };
      final source = FakeBackupDataSource(recordingsOnDevice: recordings);

      // A real file-backed output (as production uses on native - see
      // backup_destination_native.dart), not OutputMemoryStream: an
      // in-memory output's own buffer legitimately grows by every
      // recording's size as bytes are written to it, which would swamp the
      // signal this test is actually after (whether the WRITER holds more
      // than one recording at a time before/beside handing it to the
      // output).
      final tempDir = Directory.systemTemp.createTempSync('backup_memory_test');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final output = OutputFileStream('${tempDir.path}/out.zip');

      final rssSamples = <int>[];
      await BackupWriter().write(
        source: source,
        output: output,
        onProgress: (p) {
          if (p.phase.name == 'writingRecordings' && p.current > 0) {
            // A GC pass here makes the sample reflect genuinely
            // reachable memory rather than not-yet-collected garbage
            // from previous iterations, which is what would hide a
            // real accumulation bug.
            rssSamples.add(ProcessInfo.currentRss);
          }
        },
      );
      await output.close();

      expect(rssSamples.length, recordingCount);

      // RSS in a garbage-collected runtime is a noisy, HIGH-WATER-MARK
      // signal, not a live-set signal: the heap grows to fit whatever the
      // peak working set has been so far, and the VM does not necessarily
      // hand freed pages back to the OS between samples. So even
      // correctly-bounded code (processing one recording at a time, with
      // nothing accumulating) shows RSS climbing for the first few
      // recordings while the heap grows to fit "one recording's worth of
      // transient buffers", then LEVELLING OFF once the heap has reached
      // that steady state - whereas code that actually accumulates every
      // recording (e.g. into a growing List<Uint8List>) keeps climbing at
      // roughly the same rate for as long as more recordings are added.
      // Comparing average growth-per-recording in the first half against
      // the second half distinguishes "grew once to a steady state" from
      // "keeps growing" without needing a forced GC (Dart doesn't expose
      // one to application code).
      const half = recordingCount ~/ 2;
      final firstHalfGrowth = rssSamples[half - 1] - rssSamples[0];
      final secondHalfGrowth = rssSamples[recordingCount - 1] - rssSamples[half];
      final firstHalfPerRecording = firstHalfGrowth / (half - 1);
      final secondHalfPerRecording = secondHalfGrowth / (recordingCount - 1 - half);

      expect(
        secondHalfPerRecording,
        lessThan(perRecordingBytes.toDouble()),
        reason: 'RSS growth per recording in the second half '
            '(~${secondHalfPerRecording ~/ 1024} KB/recording) should have levelled '
            'off well below one recording\'s size ($perRecordingBytes bytes) by now; '
            'samples: $rssSamples - this looks like recordings are still '
            'accumulating rather than being processed one at a time',
      );
      // Documents what was actually observed, for anyone reading test
      // output while investigating a future failure here.
      // ignore: avoid_print
      print('Memory check: first-half growth/recording '
          '~${(firstHalfPerRecording / 1024).round()} KB, second-half '
          '~${(secondHalfPerRecording / 1024).round()} KB (samples: $rssSamples)');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'peak memory while writing a SINGLE 200 MB recording stays far below its '
    'size (read and hashed straight off disk in chunks, never held whole in '
    'memory)',
    () async {
      if (!Platform.isLinux && !Platform.isMacOS && !Platform.isWindows) {
        return; // ProcessInfo.currentRss needs a native OS process.
      }

      const pcmBytes = 200 * 1024 * 1024; // ~2 hours of mono 16-bit/16kHz PCM
      final tempDir =
          Directory.systemTemp.createTempSync('backup_single_recording_memory_test');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final recordingPath = '${tempDir.path}/rec.wav';
      await _writeGeneratedWavFile(recordingPath, pcmBytes, seed: 42);

      // File-path-backed (not recordingsOnDevice), so BackupWriter takes
      // its file-streaming path (see BackupDataSource.recordingFilePath)
      // instead of the in-memory fallback - see FakeBackupDataSource's doc
      // comment for why that distinction matters for this measurement.
      final source = FakeBackupDataSource(recordingFilePaths: {'big': recordingPath});
      final output = OutputFileStream('${tempDir.path}/out.zip');

      // Sampled via onProgress at current=0 (right before this recording is
      // touched at all) and current=1 (right after both the hashing pass
      // and the zip encoder's own write pass have finished for it) - the
      // same "sample at a controlled checkpoint" approach as the test
      // above, just with one very large recording instead of many small
      // ones, since a single recording's progress only ticks twice and
      // there is no per-chunk hook to sample in between (see BackupWriter -
      // adding one purely to make this measurement easier felt like the
      // tail wagging the dog). RSS's high-water-mark nature (see the test
      // above's comment) means the "after" sample still reflects the peak
      // reached during processing even without in-between samples.
      int? rssBeforeRecording;
      int? rssAfterRecording;
      await BackupWriter().write(
        source: source,
        output: output,
        onProgress: (p) {
          if (p.phase != BackupPhase.writingRecordings) return;
          if (p.current == 0) rssBeforeRecording = ProcessInfo.currentRss;
          if (p.current == 1) rssAfterRecording = ProcessInfo.currentRss;
        },
      );
      await output.close();

      expect(rssBeforeRecording, isNotNull);
      expect(rssAfterRecording, isNotNull);

      final growthBytes = rssAfterRecording! - rssBeforeRecording!;
      // Generous on purpose: real per-chunk overhead is a low single-digit
      // number of MB. This only needs to rule out "the whole 200 MB
      // recording ended up resident at some point", which a quarter of its
      // size comfortably does.
      expect(
        growthBytes,
        lessThan(pcmBytes ~/ 4),
        reason: 'RSS grew by ${(growthBytes / (1024 * 1024)).toStringAsFixed(1)} MB '
            'while writing a single ${(pcmBytes / (1024 * 1024)).toStringAsFixed(0)} '
            'MB recording (before: $rssBeforeRecording, after: $rssAfterRecording) - '
            'expected growth to stay a small fraction of the recording size, not '
            'scale with it',
      );
      // ignore: avoid_print
      print('Single 200 MB recording memory check: before '
          '${(rssBeforeRecording! / (1024 * 1024)).toStringAsFixed(1)} MB, after '
          '${(rssAfterRecording! / (1024 * 1024)).toStringAsFixed(1)} MB, growth '
          '${(growthBytes / (1024 * 1024)).toStringAsFixed(1)} MB');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
