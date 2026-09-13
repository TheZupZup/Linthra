import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/desktop_notification_preferences.dart';
import 'in_memory_desktop_notification_preferences.dart';
import 'shared_preferences_desktop_notification_preferences.dart';

/// The user's desktop-notification preferences (currently "notify me when the
/// track changes"). In-memory by default so tests and dev runs need no
/// plugins; the app persists them via `shared_preferences` through
/// [sharedPreferencesDesktopNotificationPreferencesOverride].
final desktopNotificationPreferencesProvider =
    Provider<DesktopNotificationPreferences>((ref) {
  return InMemoryDesktopNotificationPreferences();
});

final sharedPreferencesDesktopNotificationPreferencesOverride =
    desktopNotificationPreferencesProvider.overrideWithValue(
  const SharedPreferencesDesktopNotificationPreferences(),
);
