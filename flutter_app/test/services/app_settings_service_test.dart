// Unit tests for AppSettingsService: persistence of both language
// overrides, and effectiveRecordingLanguage's "Automatic" resolution.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/services/app_settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // effectiveAppLocale() reads WidgetsBinding.instance.platformDispatcher,
  // which - unlike SharedPreferences' own test-mode mock storage - needs
  // the test binding actually initialized, even for these plain test()s
  // (not testWidgets()) that never pump a widget.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('defaults to System/Automatic (both overrides null) before anything is set',
      () async {
    final settings = AppSettingsService();
    await settings.initialize();

    expect(settings.languageOverride, isNull);
    expect(settings.recordingLanguageOverride, isNull);
  });

  test('setLanguageOverride persists across a fresh instance', () async {
    final settings = AppSettingsService();
    await settings.initialize();
    await settings.setLanguageOverride(const Locale('de'));
    expect(settings.languageOverride, const Locale('de'));

    final reloaded = AppSettingsService();
    await reloaded.initialize();
    expect(reloaded.languageOverride, const Locale('de'));

    // Setting it back to "System" (null) must persist too, not just leave
    // the old value behind.
    await settings.setLanguageOverride(null);
    final reloadedAgain = AppSettingsService();
    await reloadedAgain.initialize();
    expect(reloadedAgain.languageOverride, isNull);
  });

  test('setRecordingLanguageOverride persists independently of the app language',
      () async {
    final settings = AppSettingsService();
    await settings.initialize();
    await settings.setLanguageOverride(const Locale('de'));
    await settings.setRecordingLanguageOverride('en');

    expect(settings.languageOverride, const Locale('de'));
    expect(settings.recordingLanguageOverride, 'en');

    final reloaded = AppSettingsService();
    await reloaded.initialize();
    expect(reloaded.languageOverride, const Locale('de'));
    expect(reloaded.recordingLanguageOverride, 'en');
  });

  test('effectiveRecordingLanguage uses the explicit override when set, '
      'regardless of the app language', () async {
    final settings = AppSettingsService();
    await settings.initialize();
    await settings.setLanguageOverride(const Locale('en'));
    await settings.setRecordingLanguageOverride('de');

    expect(settings.effectiveRecordingLanguage, 'de');
  });

  test('effectiveRecordingLanguage falls back to the app language override '
      'when "Automatic"', () async {
    final settings = AppSettingsService();
    await settings.initialize();
    await settings.setLanguageOverride(const Locale('de'));
    // recordingLanguageOverride left null ("Automatic").

    expect(settings.effectiveRecordingLanguage, 'de');
    expect(settings.effectiveAppLocale(), const Locale('de'));
  });

  test('effectiveAppLocale never throws without a BuildContext (safe from initState)',
      () async {
    // The whole point of effectiveAppLocale()/effectiveRecordingLanguage
    // is that they can be called from initState() (see
    // QuickAddSheet/AddEventScreen's RecorderController construction),
    // where Localizations.localeOf(context) would throw - this just
    // proves it needs no context/widget tree at all.
    final settings = AppSettingsService();
    await settings.initialize();
    expect(() => settings.effectiveAppLocale(), returnsNormally);
    expect(settings.effectiveAppLocale().languageCode, anyOf('en', 'de'));
  });
}
