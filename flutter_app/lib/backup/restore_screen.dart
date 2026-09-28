import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/database_service.dart';
import 'backup_exceptions.dart';
import 'backup_preview_text.dart';
import 'backup_progress.dart';
import 'backup_restore_result.dart';
import 'backup_restorer.dart';
import 'backup_service.dart';
import 'backup_source.dart';

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
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.backupRestoreTitle)),
      body: switch (_step) {
        _Step.pickFile => const Center(child: CircularProgressIndicator()),
        _Step.preview => _buildPreview(context),
        _Step.running => _buildRunning(context),
        _Step.done => _buildDone(context),
      },
    );
  }

  Widget _buildPreview(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final error = _error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.backupRestoreFailedTitle,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(error is BackupRestoreException ? error.message : error.toString()),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _closeClearingPickedFileCache,
                child: Text(l10n.commonClose),
              ),
            ),
          ],
        ),
      );
    }

    final manifest = _preview!.manifest;
    final createdAt =
        DateFormat.yMd(Localizations.localeOf(context).toString()).add_Hm().format(
              manifest.createdAt.toLocal(),
            );
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.backupRestorePreviewTitle, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(l10n.backupRestorePreviewCreatedAt(createdAt)),
          const SizedBox(height: 8),
          Text(backupPreviewCountsText(l10n, manifest.counts)),
          const SizedBox(height: 8),
          Text(l10n.backupRecordingsSummary(
              manifest.recordings.length, manifest.totalRecordingBytes)),
          if (manifest.missingAudio.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(l10n.backupMissingAudioWarning(manifest.missingAudio.length)),
          ],
          const SizedBox(height: 16),
          Text(l10n.backupRestorePreviewExplain,
              style: Theme.of(context).textTheme.bodySmall),
          const Spacer(),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _closeClearingPickedFileCache,
                  child: Text(l10n.commonCancel),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _confirmAndStart,
                  child: Text(l10n.backupRestorePreviewConfirm),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRunning(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final progress = _progress;
    final total = progress?.total ?? 0;
    final current = progress?.current ?? 0;
    final phaseLabel = switch (progress?.phase) {
      BackupPhase.restoringRecordings =>
        l10n.backupPhaseRestoringRecordings(current, total),
      BackupPhase.restoringData => l10n.backupPhaseRestoringData,
      _ => l10n.backupRestoringTitle,
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
            child: Text(l10n.commonCancel),
          ),
        ],
      ),
    );
  }

  Widget _buildDone(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final error = _error;
    final result = _result;
    if (error != null || result == null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.backupRestoreFailedTitle,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(error is BackupRestoreException ? error.message : '$error'),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.commonClose),
              ),
            ),
          ],
        ),
      );
    }

    final warnings = <String>[
      for (final r in result.recordings)
        if (r.outcome == RecordingOutcome.conflictKept)
          l10n.backupRecordingConflictWarning(r.id)
        else if (r.outcome == RecordingOutcome.checksumMismatch)
          l10n.backupRecordingChecksumWarning(r.id)
        else if (r.outcome == RecordingOutcome.invalidId)
          l10n.backupRecordingInvalidIdWarning(r.id),
    ];

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary, size: 48),
          const SizedBox(height: 12),
          Text(l10n.backupRestoreResultTitle, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(l10n.backupRestoreResultEntities(
              result.addedCount, result.updatedCount, result.skippedCount)),
          const SizedBox(height: 4),
          Text(l10n.backupRestoreResultRecordings(
              result.recordingsRestoredCount, result.recordingsAlreadyPresentCount)),
          if (warnings.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(l10n.backupRestoreWarningsTitle,
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
              onPressed: () => _finishSuccessfulRestore(context),
              child: Text(l10n.backupDoneButton),
            ),
          ),
        ],
      ),
    );
  }

  /// "Done" after a successful restore doesn't just pop back one screen:
  /// entity data just changed underneath whatever screens are already
  /// open, and most of them (see the final report for exactly which)
  /// loaded their data once in `initState` rather than listening to
  /// [DatabaseService], so they'd otherwise keep showing pre-restore data
  /// indefinitely. Popping all the way back to the app's first route and
  /// notifying [DatabaseService] covers what this screen can do about that
  /// on its own: routes popped past here are disposed and will reload
  /// fresh next time they're pushed again, and any ALREADY-reactive screen
  /// still on the stack (one that listens via `Consumer<DatabaseService>`/
  /// `context.watch`) picks up the change immediately. A screen that does
  /// neither - kept alive without listening - needs that other agent's fix
  /// to actually refresh; this alone can't reach it.
  void _finishSuccessfulRestore(BuildContext context) {
    context.read<DatabaseService>().notifyDataRestored();
    Navigator.of(context).popUntil((route) => route.isFirst);
  }
}
