import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import '../models/models.dart';
import '../services/recording_file_store.dart';

/// Plays back a recording's original audio straight from a
/// [RecordingFileStore], with play/pause, seek and duration - on Android
/// and web alike.
///
/// This plays from [RecordingFileStore.openPlaybackSource]: the local file
/// on native (via `DeviceFileSource`), or a `blob:` object URL on web (via
/// `UrlSource`) - never a base64 `data:` URI built from the whole file,
/// which for a long recording (~115 MB of WAV for an hour) becomes a
/// ~150 MB string that fails or freezes both native platforms and
/// browsers. The source is released (revoking the web object URL) in
/// [dispose].
class RecordingPlayer extends StatefulWidget {
  final AttachedFile file;
  final RecordingFileStore store;

  const RecordingPlayer({super.key, required this.file, required this.store});

  @override
  State<RecordingPlayer> createState() => RecordingPlayerState();
}

class RecordingPlayerState extends State<RecordingPlayer> {
  final AudioPlayer _player = AudioPlayer();
  bool _loading = true;
  String? _error;
  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  PlaybackSource? _source;

  @override
  void initState() {
    super.initState();
    if (widget.file.durationMs != null) {
      _duration = Duration(milliseconds: widget.file.durationMs!);
    }
    _player.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _isPlaying = state == PlayerState.playing);
    });
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _position = Duration.zero;
        });
      }
    });
    _load();
  }

  Future<void> _load() async {
    try {
      final source = await widget.store.openPlaybackSource(widget.file.id);
      if (!mounted) {
        source.release();
        return;
      }
      _source = source;
      final playerSource = source.filePath != null
          ? DeviceFileSource(source.filePath!)
          : UrlSource(source.objectUrl!);
      await _player.setSource(playerSource);
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      _showError(e);
    }
  }

  void _showError(Object error) {
    if (mounted) {
      setState(() {
        _error = '$error';
        _loading = false;
        _isPlaying = false;
      });
    }
  }

  Future<void> _togglePlayPause() async {
    try {
      if (_isPlaying) {
        await _player.pause();
      } else {
        await _player.resume();
      }
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _seek(double positionMs) async {
    try {
      await _player.seek(Duration(milliseconds: positionMs.round()));
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _disposePlayer() async {
    try {
      await _player.dispose();
    } catch (_) {
      // Teardown cannot show an error after this widget has been removed.
    } finally {
      // Revoke the URL only after the media element has stopped using it.
      _source?.release();
    }
  }

  @override
  void dispose() {
    _disposePlayer();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final minutes = two(d.inMinutes.remainder(60));
    final seconds = two(d.inSeconds.remainder(60));
    return d.inHours > 0 ? '${two(d.inHours)}:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return ListTile(
        leading: const Icon(Icons.error_outline, color: Colors.red),
        title: Text(widget.file.fileName),
        subtitle: Text(l10n.recordingPlayerFailedToLoad),
      );
    }

    final maxMs = _duration.inMilliseconds > 0 ? _duration.inMilliseconds.toDouble() : 1.0;
    final positionMs = _position.inMilliseconds.toDouble().clamp(0.0, maxMs);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            IconButton(
              icon: Icon(
                  _isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled),
              iconSize: 40,
              onPressed: _togglePlayPause,
              tooltip: _isPlaying ? l10n.recordingPlayerPause : l10n.recordingPlayerPlay,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Slider(
                    value: positionMs,
                    min: 0,
                    max: maxMs,
                    onChanged: _seek,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_formatDuration(_position)),
                        Text(_formatDuration(_duration)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
