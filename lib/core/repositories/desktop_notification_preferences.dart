/// The user's desktop-notification preferences (issue #400).
///
/// One choice today: whether a track change shows a notification. Kept behind
/// an interface like [DesktopWindowPreferences] so the notification path can
/// read it without binding to a storage plugin, and so tests can hand it a
/// value with no plugin registered at all.
abstract interface class DesktopNotificationPreferences {
  /// Whether a track change shows a desktop notification.
  ///
  /// Defaults to **false**. A desktop shell already draws a now-playing card
  /// from Linthra's MPRIS session, so a toast per track is an addition the
  /// listener asks for rather than something a music player should start
  /// doing to their screen on its own.
  Future<bool> trackChangeNotifications();

  Future<void> setTrackChangeNotifications(bool enabled);
}
