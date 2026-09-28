// Regression/consistency test for the ARB files: every key in
// app_en.arb must exist in app_de.arb, and vice versa - a missing key
// silently falls back to English for German users (or crashes, depending
// on the missing key) - and every key's value must reference the same
// set of {placeholder} tokens in both languages: a translation that
// dropped or renamed one is a runtime `NoSuchMethodError` waiting to
// happen the first time that string is built with real arguments.
//
// Placeholders are extracted straight from each ARB *value* (not from
// `@key` metadata blocks): gen_l10n only requires those on the template
// (English) file - a secondary-locale ARB is normally just plain
// key/value translations - so comparing metadata directly would flag
// every single placeholder-using key in app_de.arb as "missing" even
// though the app builds and runs correctly.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Matches an ICU placeholder token: `{name}` or, for plural/select,
/// `{name,`.
final _placeholderToken = RegExp(r'\{(\w+)[,}]');

Set<String> _placeholdersIn(String value) =>
    _placeholderToken.allMatches(value).map((m) => m.group(1)!).toSet();

/// Reads an ARB file into {key: value} - skipping `@@locale` and other
/// metadata entries (keys starting with `@`).
Map<String, String> _messages(String path) {
  final json = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final entry in json.entries)
      if (!entry.key.startsWith('@')) entry.key: entry.value as String,
  };
}

void main() {
  const enPath = 'lib/l10n/app_en.arb';
  const dePath = 'lib/l10n/app_de.arb';

  test('app_en.arb and app_de.arb declare exactly the same keys', () {
    final en = _messages(enPath).keys.toSet();
    final de = _messages(dePath).keys.toSet();

    expect(en.difference(de), isEmpty,
        reason: 'keys only in app_en.arb (missing German translation)');
    expect(de.difference(en), isEmpty,
        reason: 'keys only in app_de.arb (stale - removed from English, or a typo)');
  });

  test('every key references the same placeholders in both languages', () {
    final en = _messages(enPath);
    final de = _messages(dePath);

    for (final key in en.keys) {
      if (!de.containsKey(key)) continue; // reported by the key-parity test above
      expect(_placeholdersIn(de[key]!), _placeholdersIn(en[key]!),
          reason: '"$key" references different {placeholders} in app_de.arb '
              'than in app_en.arb');
    }
  });

  test('no ARB value is empty', () {
    for (final path in [enPath, dePath]) {
      _messages(path).forEach((key, value) {
        expect(value, isNotEmpty, reason: '"$key" in $path is empty');
      });
    }
  });
}
