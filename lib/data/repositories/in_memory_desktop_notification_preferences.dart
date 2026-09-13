import '../../core/repositories/desktop_notification_preferences.dart';

/// A non-persistent [DesktopNotificationPreferences] for development and
/// tests.
class InMemoryDesktopNotificationPreferences
    implements DesktopNotificationPreferences {
  InMemoryDesktopNotificationPreferences({bool trackChanges = false})
      : _trackChanges = trackChanges;

  bool _trackChanges;

  @override
  Future<bool> trackChangeNotifications() async => _trackChanges;

  @override
  Future<void> setTrackChangeNotifications(bool enabled) async {
    _trackChanges = enabled;
  }
}
