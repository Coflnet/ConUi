import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted app-wide preferences: the UI language override (Settings ->
/// Language) and which language recordings are transcribed in (Settings ->
/// Language of recordings). Both are "unset unless the user picked
/// something" - unset means "System" for the UI language and "Automatic"
/// (the app's own effective language) for the recording language.
class AppSettingsService extends ChangeNotifier {
  static const _languageKey = 'settings_app_language';
  static const _recordingLanguageKey = 'settings_recording_language';

  bool _initialized = false;
  bool get isInitialized => _initialized;

  Locale? _languageOverride;

  /// Null means "follow the system language" - passed straight through to
  /// MaterialApp.locale, which resolves it against supportedLocales itself.
  Locale? get languageOverride => _languageOverride;

  String? _recordingLanguageOverride;

  /// Null means "Automatic" (the app's own effective language, see
  /// [effectiveRecordingLanguage]); otherwise an explicit language code
  /// ('de'/'en') to always transcribe as, regardless of spoken content.
  String? get recordingLanguageOverride => _recordingLanguageOverride;

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final lang = prefs.getString(_languageKey);
    _languageOverride = lang == null ? null : Locale(lang);
    _recordingLanguageOverride = prefs.getString(_recordingLanguageKey);
    _initialized = true;
    notifyListeners();
  }

  Future<void> setLanguageOverride(Locale? locale) async {
    _languageOverride = locale;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (locale == null) {
      await prefs.remove(_languageKey);
    } else {
      await prefs.setString(_languageKey, locale.languageCode);
    }
  }

  Future<void> setRecordingLanguageOverride(String? languageCode) async {
    _recordingLanguageOverride = languageCode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (languageCode == null) {
      await prefs.remove(_recordingLanguageKey);
    } else {
      await prefs.setString(_recordingLanguageKey, languageCode);
    }
  }

  /// The app's currently active language: the explicit override, or -
  /// matching main.dart's own MaterialApp.supportedLocales resolution
  /// (English first, German for any `de*` device locale) - German if any
  /// of the device's preferred locales is German, English otherwise.
  ///
  /// Deliberately not `Localizations.localeOf(context)`: that establishes
  /// an InheritedWidget dependency, which is illegal to do from
  /// `initState()` (exactly where RecorderController's `language:` needs
  /// to be resolved, in QuickAddSheet/AddEventScreen) - this reads the
  /// platform's own locale list directly instead, so it's safe anywhere.
  Locale effectiveAppLocale() {
    final override = _languageOverride;
    if (override != null) return override;
    final deviceLocales = WidgetsBinding.instance.platformDispatcher.locales;
    final isGerman = deviceLocales.any((l) => l.languageCode == 'de');
    return isGerman ? const Locale('de') : const Locale('en');
  }

  /// The language code to actually pass as transcription's `language`
  /// parameter: the explicit recording-language override if one is set,
  /// otherwise [effectiveAppLocale]'s own language code ("Automatic").
  String get effectiveRecordingLanguage =>
      _recordingLanguageOverride ?? effectiveAppLocale().languageCode;
}
