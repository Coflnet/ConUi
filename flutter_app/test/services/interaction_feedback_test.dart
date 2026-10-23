import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:relationship_manager/services/app_settings_service.dart';
import 'package:relationship_manager/services/interaction_feedback.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('independent feedback preferences survive restart', () async {
    final settings = AppSettingsService();
    await settings.initialize();
    expect(settings.hapticsEnabled, isTrue);
    expect(settings.soundsEnabled, isFalse);
    await settings.setHapticsEnabled(false);
    await settings.setSoundsEnabled(true);
    final restored = AppSettingsService();
    await restored.initialize();
    final haptics = <FeedbackCue>[], sounds = <FeedbackCue>[];
    final feedback = InteractionFeedback(restored,
        hapticPlayer: (cue) async => haptics.add(cue),
        soundPlayer: (cue) async => sounds.add(cue));
    await feedback.play(FeedbackCue.success);
    expect(haptics, isEmpty);
    expect(sounds, [FeedbackCue.success]);
    await restored.setSoundsEnabled(false);
    await feedback.play(FeedbackCue.error);
    expect(sounds, hasLength(1));
  });

  test('recording waits for feedback then suppresses all cues until stop', () async {
    final settings = AppSettingsService();
    await settings.setSoundsEnabled(true);
    final firstSound = Completer<void>();
    final sound = <FeedbackCue>[], haptic = <FeedbackCue>[];
    final feedback = InteractionFeedback(settings,
      soundPlayer: (cue) async {
        sound.add(cue);
        if (cue == FeedbackCue.success) await firstSound.future;
      },
      hapticPlayer: (cue) async => haptic.add(cue),
    );
    final saving = feedback.play(FeedbackCue.success);
    var canCapture = false;
    final starting = feedback.beginRecording().then((_) => canCapture = true);
    await feedback.play(FeedbackCue.selection);
    expect(canCapture, isFalse);
    expect(sound, [FeedbackCue.success]);
    firstSound.complete();
    await saving;
    await starting;
    expect(canCapture, isTrue);
    expect(sound, [FeedbackCue.success, FeedbackCue.recordingStart]);
    for (final cue in FeedbackCue.values) { await feedback.play(cue); }
    expect(sound, hasLength(2));
    expect(haptic, hasLength(2));
    await feedback.endRecording();
    expect(sound.last, FeedbackCue.recordingStop);
    expect(haptic.last, FeedbackCue.recordingStop);
    await feedback.play(FeedbackCue.selection);
    expect(sound.last, FeedbackCue.selection);
  });

  test('unsupported feedback does not block recording or later actions', () async {
    final settings = AppSettingsService();
    await settings.setSoundsEnabled(true);
    final feedback = InteractionFeedback(settings,
      soundPlayer: (_) async => throw StateError('Autoplay blocked'),
      hapticPlayer: (_) async => throw UnsupportedError('No haptic hardware'),
    );
    await feedback.beginRecording();
    await feedback.endRecording(failed: true);
    await feedback.play(FeedbackCue.success);
    feedback.dispose();
    await feedback.play(FeedbackCue.success);
  });
}
