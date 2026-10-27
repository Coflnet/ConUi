import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/sync_service.dart';

/// Progress and estimates describe the current step, whose workload is known.
class SyncProgressIndicator extends StatelessWidget {
  final SyncService sync;

  const SyncProgressIndicator({super.key, required this.sync});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: sync,
        builder: (context, _) {
          final l10n = AppLocalizations.of(context);
          final phase = sync.isSyncing ? sync.phase : SyncPhase.preparing;
          final transferring =
              phase == SyncPhase.downloading || phase == SyncPhase.uploading;
          final fraction = transferring && sync.totalItems > 0
              ? sync.completedItems / sync.totalItems
              : null;
          final percent = ((fraction ?? 0) * 100).floor();
          final downloading = phase == SyncPhase.downloading;
          final label = switch (phase) {
            SyncPhase.preparing => l10n.syncPreparing,
            SyncPhase.finishing => l10n.syncFinishing,
            SyncPhase.downloading => l10n.syncDownloadStep,
            SyncPhase.uploading => l10n.syncUploadStep,
          };
          final remaining = sync.estimatedRemaining;
          final recording = sync.totalRecordingChunks > 0;
          final String estimate;
          if (recording &&
              sync.completedRecordingChunks == sync.totalRecordingChunks) {
            estimate = l10n.syncRecordingFinishing;
          } else if (remaining == null) {
            estimate =
                recording ? l10n.syncEstimatingRecording : l10n.syncEstimating;
          } else if (remaining.inSeconds < 60) {
            final seconds =
                (remaining.inMilliseconds / 1000).ceil().clamp(1, 60);
            estimate = recording
                ? l10n.syncRecordingRemainingSeconds(seconds)
                : l10n.syncRemainingSeconds(seconds);
          } else if (remaining.inMinutes < 60) {
            final minutes = (remaining.inSeconds / 60).ceil();
            estimate = recording
                ? l10n.syncRecordingRemainingMinutes(minutes)
                : l10n.syncRemainingMinutes(minutes);
          } else {
            final hours = (remaining.inMinutes / 60).ceil();
            estimate = recording
                ? l10n.syncRecordingRemainingHours(hours)
                : l10n.syncRemainingHours(hours);
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label),
              if (fraction != null)
                Text(downloading
                    ? l10n.syncDownloadProgress(
                        sync.completedItems, sync.totalItems, percent)
                    : l10n.syncUploadProgress(
                        sync.completedItems, sync.totalItems, percent)),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: fraction,
                semanticsLabel: label,
                semanticsValue: fraction == null ? null : '$percent%',
              ),
              if (transferring) ...[
                const SizedBox(height: 8),
                if (recording)
                  Text(l10n.syncRecordingProgress((100 *
                          sync.completedRecordingChunks /
                          sync.totalRecordingChunks)
                      .floor())),
                Text(estimate),
              ],
            ],
          );
        },
      );
}
