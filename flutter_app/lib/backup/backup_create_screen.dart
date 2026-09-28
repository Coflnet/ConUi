import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/database_service.dart';
import 'backup_progress.dart';
import 'backup_service.dart';
import 'backup_strings.dart';

/// "Create backup": shows what will be included (with the missing-audio
/// notice up front, per the brief), asks for confirmation, then runs the
/// backup with progress and a cancel button, and reports where the file
/// went (or what went wrong).
class BackupCreateScreen extends StatefulWidget {
  /// Reuses the caller's BackupService when given one (SettingsScreen
  /// passes its own); otherwise builds one from context. Also how tests
  /// supply a BackupService backed by fakes/temp dirs instead of the real
  /// platform channels.
  final BackupService? backupService;

  const BackupCreateScreen({super.key, this.backupService});

  @override
  State<BackupCreateScreen> createState() => _BackupCreateScreenState();
}

enum _Step { loadingPlan, showingPlan, running, done }

class _BackupCreateScreenState extends State<BackupCreateScreen> {
  late final BackupService _service;
  _Step _step = _Step.loadingPlan;
  BackupPlan? _plan;
  Object? _planError;

  bool _cancelRequested = false;
  BackupProgress? _progress;
  BackupCreateOutcome? _outcome;

  @override
  void initState() {
    super.initState();
    _service = widget.backupService ??
        BackupService(databaseService: context.read<DatabaseService>());
    _loadPlan();
  }

  Future<void> _loadPlan() async {
    try {
      final plan = await _service.planBackup();
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _step = _Step.showingPlan;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _planError = e;
        _step = _Step.showingPlan;
      });
    }
  }

  Future<void> _confirmAndStart() async {
    final plan = _plan;
    if (kIsWeb && plan != null && plan.recordingBytes > BackupService.webSizeWarnThresholdBytes) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text(BackupStrings.webSizeWarningTitle),
          content: Text(BackupStrings.webSizeWarningBody(
            BackupStrings.bytesToHuman(plan.recordingBytes),
            BackupStrings.bytesToHuman(BackupService.webSizeWarnThresholdBytes),
          )),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text(BackupStrings.cancel)),
            TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Continue')),
          ],
        ),
      );
      if (proceed != true) return;
    }

    setState(() {
      _step = _Step.running;
      _cancelRequested = false;
      _progress = const BackupProgress(phase: BackupPhase.collectingData);
    });

    final outcome = await _service.createBackup(
      isCancelled: () => _cancelRequested,
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
    );

    if (!mounted) return;
    setState(() {
      _outcome = outcome;
      _step = _Step.done;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(BackupStrings.createTitle)),
      body: switch (_step) {
        _Step.loadingPlan => const Center(child: CircularProgressIndicator()),
        _Step.showingPlan => _buildPlan(context),
        _Step.running => _buildRunning(context),
        _Step.done => _buildDone(context),
      },
    );
  }

  Widget _buildPlan(BuildContext context) {
    final plan = _plan;
    if (plan == null) {
      return Center(child: Text('Could not prepare a backup: $_planError'));
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(BackupStrings.previewTitle, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(BackupStrings.previewCounts(plan.counts)),
          const SizedBox(height: 8),
          Text(BackupStrings.recordingsSummary(plan.recordingCount, plan.recordingBytes)),
          if (plan.missingAudioCount > 0) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                BackupStrings.missingAudioWarning(plan.missingAudioCount),
                style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
              ),
            ),
          ],
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _confirmAndStart,
              child: const Text(BackupStrings.createTitle),
            ),
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
      BackupPhase.collectingData => 'Reading your data…',
      BackupPhase.writingRecordings => 'Writing recordings ($current of $total)…',
      BackupPhase.writingMetadata => 'Writing data…',
      BackupPhase.verifying => BackupStrings.verifying,
      _ => BackupStrings.creatingTitle,
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
    final outcome = _outcome;
    return switch (outcome) {
      BackupCreateSuccess(:final manifest, :final location) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary, size: 48),
              const SizedBox(height: 12),
              Text(BackupStrings.createSuccessTitle,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(location.isFilePath
                  ? BackupStrings.createSuccessSavedTo(location.description)
                  : BackupStrings.createSuccessDownloaded),
              if (manifest.missingAudio.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(BackupStrings.missingAudioWarning(manifest.missingAudio.length)),
              ],
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
        ),
      BackupCreateCancelled() => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(BackupStrings.createCancelledTitle,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text(BackupStrings.createCancelledBody),
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
        ),
      BackupCreateFailed(:final message) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error, color: Theme.of(context).colorScheme.error, size: 48),
              const SizedBox(height: 12),
              Text(BackupStrings.createFailedTitle,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(message),
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
        ),
      null => const SizedBox.shrink(),
    };
  }
}
