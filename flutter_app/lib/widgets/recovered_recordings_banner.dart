import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../screens/map/location_picker_screen.dart';
import '../screens/quick_add/quick_add_sheet.dart';
import '../services/database_service.dart';
import '../services/recording_file_store.dart';
import 'recording_player.dart';

class _Strings {
  static const review = 'Review';
  static const sheetTitle = 'Recordings not attached to a story';
  static const attach = 'Attach to a new story';
  static const delete = 'Delete';
  static const deleteTitle = 'Delete this recording?';
  static const deleteBody =
      'This permanently deletes the audio. This cannot be undone.';
  static const cancel = 'Cancel';

  static String banner(int count) =>
      count == 1 ? '1 recording is not attached to a story' : '$count recordings are not attached to a story';
}

AttachedFile _asAttachedFile(LocalRecordingState r) => AttachedFile(
      id: r.id,
      fileName: '${r.id}.wav',
      filePath: r.id,
      mimeType: 'audio/wav',
      size: r.sizeBytes ?? 0,
      durationMs: r.durationMs,
      sha256: r.sha256,
      kind: AttachedFile.kindRecording,
    );

/// Banner shown on the map when this device has recordings that were
/// captured but never ended up attached to a story - either the quick add
/// sheet was dismissed before saving, or RecordingRecoveryService found
/// them abandoned after a crash. Offers to listen, attach one to a new
/// story, or delete it (with confirmation, per RecordingFileStore's
/// deletion rule).
class RecoveredRecordingsBanner extends StatefulWidget {
  final RecordingFileStore store;

  /// Where a newly opened location picker (for "attach to a new story")
  /// should start - normally the map's current camera center.
  final LatLng pickerStartPosition;

  const RecoveredRecordingsBanner({
    super.key,
    required this.store,
    required this.pickerStartPosition,
  });

  @override
  State<RecoveredRecordingsBanner> createState() => RecoveredRecordingsBannerState();
}

class RecoveredRecordingsBannerState extends State<RecoveredRecordingsBanner> {
  List<LocalRecordingState> _orphaned = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    final db = context.read<DatabaseService>();
    final orphaned = await db.getOrphanedRecordings();
    if (!mounted) return;
    setState(() {
      _orphaned = orphaned;
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || _orphaned.isEmpty) return const SizedBox.shrink();
    return MaterialBanner(
      leading: const Icon(Icons.mic_off_outlined),
      content: Text(_Strings.banner(_orphaned.length)),
      actions: [
        TextButton(onPressed: _openReview, child: const Text(_Strings.review)),
      ],
    );
  }

  void _openReview() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _OrphanedRecordingsSheet(
        store: widget.store,
        recordings: _orphaned,
        pickerStartPosition: widget.pickerStartPosition,
        onChanged: refresh,
      ),
    );
  }
}

class _OrphanedRecordingsSheet extends StatelessWidget {
  final RecordingFileStore store;
  final List<LocalRecordingState> recordings;
  final LatLng pickerStartPosition;
  final Future<void> Function() onChanged;

  const _OrphanedRecordingsSheet({
    required this.store,
    required this.recordings,
    required this.pickerStartPosition,
    required this.onChanged,
  });

  Future<void> _attach(BuildContext context, LocalRecordingState recording) async {
    final position = await Navigator.push<LatLng>(
      context,
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(initialPosition: pickerStartPosition),
      ),
    );
    if (position == null || !context.mounted) return;

    final notifier = ValueNotifier<LatLng>(position);
    final result = await QuickAddSheet.show(context, position: notifier);
    notifier.dispose();
    // The quick add sheet's own recorder is independent of this recovered
    // recording - this attaches it to the freshly created story alongside
    // whatever (if anything) the sheet itself recorded there, by adding it
    // to the event's files and pointing its local bookkeeping at the new
    // event, exactly like a normal save does for a recording made in the
    // sheet.
    if (result != null && context.mounted) {
      final db = context.read<DatabaseService>();
      final file = _asAttachedFile(recording);
      final updatedEvent = result.event.copyWith(files: [...result.event.files, file]);
      await db.saveEvent(updatedEvent);
      await db.saveLocalRecording(recording.copyWith(eventId: updatedEvent.id));
      await onChanged();
      if (context.mounted) Navigator.pop(context);
    }
  }

  Future<void> _delete(BuildContext context, LocalRecordingState recording) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text(_Strings.deleteTitle),
        content: const Text(_Strings.deleteBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text(_Strings.cancel)),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text(_Strings.delete, style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final db = context.read<DatabaseService>();
    await db.deleteRecordingPermanently(recording.id, store);
    await onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_Strings.sheetTitle, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.6),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: recordings.length,
                itemBuilder: (context, index) {
                  final recording = recordings[index];
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          RecordingPlayer(file: _asAttachedFile(recording), store: store),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton.icon(
                                onPressed: () => _attach(context, recording),
                                icon: const Icon(Icons.add_location_alt_outlined),
                                label: const Text(_Strings.attach),
                              ),
                              TextButton.icon(
                                onPressed: () => _delete(context, recording),
                                icon: const Icon(Icons.delete_outline, color: Colors.red),
                                label: const Text(_Strings.delete, style: TextStyle(color: Colors.red)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
