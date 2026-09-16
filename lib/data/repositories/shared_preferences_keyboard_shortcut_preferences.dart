import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/keyboard_shortcut_preferences.dart';

/// A [KeyboardShortcutPreferences] backed by `shared_preferences`.
///
/// A handful of short strings, so they live beside the other small user choices
/// in the key/value store rather than in the SQLite catalog. Nothing here is a
/// secret: a key combination is not a credential, which is why this is the
/// plain preferences tier and not secure storage.
///
/// One flat key per action (`keyboard_shortcut.play_pause`) rather than one
/// encoded blob. Reading a single override cannot then be broken by another's
/// bad value, and removing an override is a delete rather than a rewrite of
/// everything.
class SharedPreferencesKeyboardShortcutPreferences
    implements KeyboardShortcutPreferences {
  const SharedPreferencesKeyboardShortcutPreferences();

  static const String _prefix = 'keyboard_shortcut.';

  @override
  Future<Map<String, String>> overrides() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final Map<String, String> stored = <String, String>{};
    for (final String key in prefs.getKeys()) {
      if (!key.startsWith(_prefix)) continue;
      // Written by a build that stored something other than a string under
      // this prefix: skip it rather than throwing on launch.
      final Object? value = prefs.get(key);
      if (value is! String) continue;
      stored[key.substring(_prefix.length)] = value;
    }
    return stored;
  }

  @override
  Future<void> setOverride(String storageKey, String? binding) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (binding == null) {
      await prefs.remove('$_prefix$storageKey');
      return;
    }
    await prefs.setString('$_prefix$storageKey', binding);
  }

  @override
  Future<void> clear() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    for (final String key in prefs.getKeys().toList()) {
      if (key.startsWith(_prefix)) await prefs.remove(key);
    }
  }
}
