import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Explicitly saved, device-local form drafts. Attachments remain in their stores.
class LocalDraftStore {
  static const _prefix = 'form_draft.v1.';

  static Future<Map<String, dynamic>?> read(String key) async {
    final value =
        (await SharedPreferences.getInstance()).getString('$_prefix$key');
    return value == null ? null : jsonDecode(value) as Map<String, dynamic>;
  }

  static Future<void> write(String key, Map<String, dynamic> value) async {
    if (!await (await SharedPreferences.getInstance())
        .setString('$_prefix$key', jsonEncode(value))) {
      throw StateError('Draft could not be saved');
    }
  }

  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().where((key) => key.startsWith(_prefix))) {
      if (!await prefs.remove(key)) {
        throw StateError('Draft could not be removed');
      }
    }
  }

  static Future<void> remove(String key) async {
    if (!await (await SharedPreferences.getInstance()).remove('$_prefix$key')) {
      throw StateError('Draft could not be removed');
    }
  }
}
