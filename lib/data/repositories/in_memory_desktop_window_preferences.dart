import '../../core/models/desktop_close_behavior.dart';
import '../../core/repositories/desktop_window_preferences.dart';

/// A non-persistent [DesktopWindowPreferences] for development and tests.
class InMemoryDesktopWindowPreferences implements DesktopWindowPreferences {
  InMemoryDesktopWindowPreferences({
    DesktopCloseBehavior closeBehavior = DesktopCloseBehavior.defaultBehavior,
  }) : _closeBehavior = closeBehavior;

  DesktopCloseBehavior _closeBehavior;

  @override
  Future<DesktopCloseBehavior> closeBehavior() async => _closeBehavior;

  @override
  Future<void> setCloseBehavior(DesktopCloseBehavior behavior) async {
    _closeBehavior = behavior;
  }
}
