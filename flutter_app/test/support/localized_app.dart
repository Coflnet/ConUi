// Test helper: wraps a widget with the same localization delegates
// production's MaterialApp uses, fixed to an explicit locale regardless of
// whatever the test host machine's own locale happens to be - see the
// l10n brief's "Make the tests run with a fixed locale and keep them
// meaningful" requirement. Defaults to English, matching what existing
// tests (written before localisation) already assert against; pass
// `locale: const Locale('de')` for a test that specifically checks German
// text.
import 'package:flutter/material.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';

Widget wrapLocalized(Widget home, {Locale locale = const Locale('en')}) {
  return MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: const [Locale('en'), Locale('de')],
    home: home,
  );
}
