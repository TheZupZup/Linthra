import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/keyboard_shortcut_preferences.dart';
import 'in_memory_keyboard_shortcut_preferences.dart';
import 'shared_preferences_keyboard_shortcut_preferences.dart';

/// The user's keyboard-shortcut overrides (#391).
///
/// In-memory by default so widget tests and dev runs need no plugin; the app
/// persists them through
/// [sharedPreferencesKeyboardShortcutPreferencesOverride], applied in `main`.
final keyboardShortcutPreferencesProvider =
    Provider<KeyboardShortcutPreferences>((ref) {
  return InMemoryKeyboardShortcutPreferences();
});

final sharedPreferencesKeyboardShortcutPreferencesOverride =
    keyboardShortcutPreferencesProvider.overrideWithValue(
  const SharedPreferencesKeyboardShortcutPreferences(),
);
