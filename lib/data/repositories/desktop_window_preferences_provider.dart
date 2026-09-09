import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/desktop_window_preferences.dart';
import 'in_memory_desktop_window_preferences.dart';
import 'shared_preferences_desktop_window_preferences.dart';

/// The user's desktop window preferences (currently "when I close the
/// window"). In-memory by default so tests and dev runs need no plugins; the
/// app persists them via `shared_preferences` through
/// [sharedPreferencesDesktopWindowPreferencesOverride].
final desktopWindowPreferencesProvider =
    Provider<DesktopWindowPreferences>((ref) {
  return InMemoryDesktopWindowPreferences();
});

final sharedPreferencesDesktopWindowPreferencesOverride =
    desktopWindowPreferencesProvider.overrideWithValue(
  const SharedPreferencesDesktopWindowPreferences(),
);
