import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/desktop_notification_preferences.dart';

/// A [DesktopNotificationPreferences] backed by `shared_preferences`. One
/// boolean, so it lives next to the other small user choices in the key/value
/// store rather than in the SQLite catalog.
class SharedPreferencesDesktopNotificationPreferences
    implements DesktopNotificationPreferences {
  const SharedPreferencesDesktopNotificationPreferences();

  static const String _trackChangesKey = 'desktop_track_change_notifications';

  @override
  Future<bool> trackChangeNotifications() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    // Unset reads as off, which is what a build without this feature did.
    return prefs.getBool(_trackChangesKey) ?? false;
  }

  @override
  Future<void> setTrackChangeNotifications(bool enabled) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_trackChangesKey, enabled);
  }
}
