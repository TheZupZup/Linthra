import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/desktop_close_behavior.dart';
import '../../core/repositories/desktop_window_preferences.dart';

/// A [DesktopWindowPreferences] backed by `shared_preferences`. One small
/// string, so it lives next to the other small user choices in the key/value
/// store rather than in the SQLite catalog.
class SharedPreferencesDesktopWindowPreferences
    implements DesktopWindowPreferences {
  const SharedPreferencesDesktopWindowPreferences();

  static const String _closeBehaviorKey = 'desktop_close_behavior';

  @override
  Future<DesktopCloseBehavior> closeBehavior() async {
    final prefs = await SharedPreferences.getInstance();
    // Unset, or written by a build that knew a different value: quit, the
    // behaviour closing the window has always had.
    return DesktopCloseBehavior.fromStorage(prefs.getString(_closeBehaviorKey));
  }

  @override
  Future<void> setCloseBehavior(DesktopCloseBehavior behavior) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_closeBehaviorKey, behavior.storageValue);
  }
}
