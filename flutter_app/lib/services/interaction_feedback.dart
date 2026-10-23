import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

import 'app_settings_service.dart';

enum FeedbackCue { selection, success, recordingStart, recordingStop, error }

/// Optional feedback never interrupts a task or enters a microphone recording.
class InteractionFeedback {
  final AppSettingsService settings;
  final Future<void> Function(FeedbackCue)? soundPlayer;
  final Future<void> Function(FeedbackCue)? hapticPlayer;
  AudioPlayer? _player;
  Future<void>? _playing;
  int _captures = 0;
  bool _disposed = false;

  InteractionFeedback(this.settings, {this.soundPlayer, this.hapticPlayer});

  Future<void> play(FeedbackCue cue) {
    if (_disposed || _captures > 0) return Future.value();
    // Coalesce rapid selections instead of playing a backlog of stale cues.
    return _playing ??= _emit(cue).whenComplete(() => _playing = null);
  }

  Future<void> beginRecording() async {
    _captures++;
    await _playing;
    if (_captures == 1 && !_disposed) {
      _playing = _emit(FeedbackCue.recordingStart);
      await _playing;
      _playing = null;
    }
  }

  Future<void> endRecording({bool failed = false, bool silent = false}) async {
    if (_captures == 0) return;
    _captures--;
    if (!silent) {
      await play(failed ? FeedbackCue.error : FeedbackCue.recordingStop);
    }
  }

  Future<void> _emit(FeedbackCue cue) async {
    Future<void> safely(Future<void> Function() action) async {
      try {
        await action();
      } catch (_) {
        // Unsupported hardware, muted audio and browser autoplay restrictions
        // must not prevent saving, selecting or starting a recording.
      }
    }

    await Future.wait([
      if (settings.hapticsEnabled)
        safely(() => hapticPlayer != null ? hapticPlayer!(cue) : _haptic(cue)),
      if (settings.soundsEnabled)
        safely(() => soundPlayer != null ? soundPlayer!(cue) : _sound(cue)),
    ]);
  }

  Future<void> _haptic(FeedbackCue cue) => switch (cue) {
        FeedbackCue.selection => HapticFeedback.selectionClick(),
        FeedbackCue.success => HapticFeedback.successNotification(),
        FeedbackCue.error => HapticFeedback.errorNotification(),
        _ => HapticFeedback.lightImpact(),
      };

  Future<void> _sound(FeedbackCue cue) async {
    final player = _player ??= AudioPlayer();
    final completed = player.onPlayerComplete.first.timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
    try {
      await player.play(AssetSource('feedback/${cue.name}.wav'),
          volume: 0.18,
          ctx: const AudioContext(
            android: AudioContextAndroid(
                contentType: AndroidContentType.sonification,
                usageType: AndroidUsageType.assistanceSonification,
                audioFocus: AndroidAudioFocus.none),
            iOS: AudioContextIOS(category: AVAudioSessionCategory.ambient),
          ));
      await completed;
    } finally {
      // In particular, finish playback before beginRecording returns.
      await player.stop();
    }
  }

  void dispose() {
    _disposed = true;
    final player = _player;
    if (player != null) unawaited(player.dispose().catchError((Object _) {}));
  }
}
