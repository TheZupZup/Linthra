import '../models/desktop_close_behavior.dart';

/// The user's desktop window preferences (issue #401).
///
/// One choice today: what closing the main window does. Kept behind an
/// interface like [PlaybackPreferences] so the lifecycle layer can read it
/// without binding to a storage plugin, and so tests can hand it a value with
/// no plugin registered at all.
abstract interface class DesktopWindowPreferences {
  /// What closing the window does. Defaults to
  /// [DesktopCloseBehavior.defaultBehavior]: quit, the behaviour Linthra has
  /// always had, so nothing changes until the user asks for it.
  Future<DesktopCloseBehavior> closeBehavior();

  Future<void> setCloseBehavior(DesktopCloseBehavior behavior);
}
