import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/database_service.dart';
import 'backup_exceptions.dart';
import 'backup_progress.dart';
import 'backup_restore_result.dart';
import 'backup_restorer.dart';
import 'backup_service.dart';
import 'backup_source.dart';
import 'backup_strings.dart';

/// "Restore from backup": pick a file, show what's in it and what will
/// happen, confirm, then run the restore with progress and report the
/// result in plain words - see the brief's step 2 for the exact rules this
/// implements (merge by id/updatedAt, recording checksum verification and
/// conflict handling, etc., all in backup_restorer.dart/
/// database_backup_adapter.dart; this file is purely presentation).
class RestoreScreen extends StatefulWidget {
  /// Reuses the caller's BackupService when given one (SettingsScreen
  /// passes its own); otherwise builds one from context. Also how tests
  /// supply a BackupService backed by fakes/temp dirs instead of the real
  /// platform channels.
  final BackupService? backupService;

  const RestoreScreen({super.key, this.backupService});

  @override
  State<RestoreScreen> createState() => _RestoreScreenState();
}

enum _Step { pickFile, preview, running, done }

class _RestoreScreenState extends State<RestoreScreen> {
  late final BackupService _service;
  _Step _step = _Step.pickFile;

  PickedBackupFile? _picked;
  BackupPreview? _preview;
  Object? _error;

  bool _cancelRequested = false;
  BackupProgress? _progress;
  RestoreResult? _result;

  @override
  void initState() {
    super.initState();
    _service = widget.backupService ??
        BackupService(databaseService: context.read<DatabaseService>());
    _pickFile();
  }

  Future<void> _pickFile() async {
    try {
      final picked = await _service.pickBackupFile();
      if (picked == null) {
        if (mounted) Navigator.of(context).maybePop();
        return;
      }
      final preview = _service.previewRestore(picked);
      if (!mounted) return;
      setState(() {
        _picked = picked;
        _preview = preview;
        _step = _Step.preview;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _step = _Step.preview;
      });
    }
  }

  Future<void> _confirmAndStart() async {
    final picked = _picked;
    if (picked == null) return;
    setState(() {
      _step = _Step.running;
      _cancelRequested = false;
      _progress = const BackupProgress(phase: BackupPhase.restoringRecordings);
    });

    try {
      final result = await _service.applyRestore(
        picked,
        isCancelled: () => _cancelRequested,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _step = _Step.done;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _result = null;
        _step = _Step.done;
      });
    } finally {
      // This restore attempt is done with the picked file either way - see
      // pickBackupFile()'s doc comment for why file_picker's own cache copy
      // of it (Android/iOS) needs an explicit clear rather than cleaning
      // itself up.
      await _service.clearPickedFileCache();
    }
  }

  /// Backing out at the preview step (whether the archive previewed fine
  /// and the user chose not to restore it, or it failed to preview at all)
  /// still leaves file_picker's cache copy of it behind on Android/iOS - see
  /// pickBackupFile()'s doc comment - so this clears it before popping,
  /// same as the success/failure paths in [_confirmAndStart].
  Future<void> _closeClearingPickedFileCache() async {
    await _service.clearPickedFileCache();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(BackupStrings.restoreTitle)),
      body: switch (_step) {
        _Step.pickFile => const Center(child: CircularProgressIndicator()),
        _Step.preview => _buildPreview(context),
        _Step.running => _buildRunning(context),
        _Step.done => _buildDone(context),
      },
    );
  }

  Widget _buildPreview(BuildContext context) {
    final error = _error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(BackupStrings.restoreFailedTitle,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(error is BackupRestoreException ? error.message : error.toString()),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _closeClearingPickedFileCache,
                child: const Text('Close'),
              ),
            ),
          ],
        ),
      );
    }

    final manifest = _preview!.manifest;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(BackupStrings.restorePreviewTitle, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(BackupStrings.restorePreviewCreatedAt(manifest.createdAt.toLocal().toString())),
          const SizedBox(height: 8),
          Text(BackupStrings.previewCounts(manifest.counts)),
          const SizedBox(height: 8),
          Text(BackupStrings.recordingsSummary(
              manifest.recordings.length, manifest.totalRecordingBytes)),
          if (manifest.missingAudio.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(BackupStrings.missingAudioWarning(manifest.missingAudio.length)),
          ],
          const SizedBox(height: 16),
          Text(BackupStrings.restorePreviewExplain,
              style: Theme.of(context).textTheme.bodySmall),
          const Spacer(),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _closeClearingPickedFileCache,
                  child: const Text(BackupStrings.restorePreviewCancel),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _confirmAndStart,
                  child: const Text(BackupStrings.restorePreviewConfirm),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRunning(BuildContext context) {
    final progress = _progress;
    final total = progress?.total ?? 0;
    final current = progress?.current ?? 0;
    final phaseLabel = switch (progress?.phase) {
      BackupPhase.restoringRecordings => 'Restoring recordings ($current of $total)…',
      BackupPhase.restoringData => 'Restoring data…',
      _ => BackupStrings.restoringTitle,
    };
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (total > 0)
            LinearProgressIndicator(value: current / total)
          else
            const LinearProgressIndicator(),
          const SizedBox(height: 16),
          Text(phaseLabel),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: () => setState(() => _cancelRequested = true),
            child: const Text(BackupStrings.cancel),
          ),
        ],
      ),
    );
  }

  Widget _buildDone(BuildContext context) {
    final error = _error;
    final result = _result;
    if (error != null || result == null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(BackupStrings.restoreFailedTitle,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(error is BackupRestoreException ? error.message : '$error'),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ),
          ],
        ),
      );
    }

    final warnings = <String>[
      for (final r in result.recordings)
        if (r.outcome == RecordingOutcome.conflictKept)
          BackupStrings.recordingConflictWarning(r.id)
        else if (r.outcome == RecordingOutcome.checksumMismatch)
          BackupStrings.recordingChecksumWarning(r.id)
        else if (r.outcome == RecordingOutcome.invalidId)
          BackupStrings.recordingInvalidIdWarning(r.id),
    ];

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary, size: 48),
          const SizedBox(height: 12),
          Text(BackupStrings.restoreResultTitle, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(BackupStrings.restoreResultEntities(
              result.addedCount, result.updatedCount, result.skippedCount)),
          const SizedBox(height: 4),
          Text(BackupStrings.restoreResultRecordings(
              result.recordingsRestoredCount, result.recordingsAlreadyPresentCount)),
          if (warnings.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(BackupStrings.restoreWarningsTitle,
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Expanded(
              child: ListView(
                children: [for (final w in warnings) Text('• $w')],
              ),
            ),
          ] else
            const Spacer(),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ),
        ],
      ),
    );
  }
}
