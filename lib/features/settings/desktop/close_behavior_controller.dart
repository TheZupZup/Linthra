import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/desktop_close_behavior.dart';
import '../../../data/repositories/desktop_window_preferences_provider.dart';

/// Owns the "When I close the window" choice: loads the persisted value and
/// writes changes back through [DesktopWindowPreferences].
///
/// Only the *stored choice* lives here. What the app does with it (whether a
/// given close actually hides the window) is
/// `DesktopWindowLifecycleService`'s decision, taken together with what
/// playback is doing.
class DesktopCloseBehaviorController
    extends AsyncNotifier<DesktopCloseBehavior> {
  @override
  Future<DesktopCloseBehavior> build() {
    return ref.read(desktopWindowPreferencesProvider).closeBehavior();
  }

  Future<void> setBehavior(DesktopCloseBehavior behavior) async {
    await ref.read(desktopWindowPreferencesProvider).setCloseBehavior(behavior);
    state = AsyncData<DesktopCloseBehavior>(behavior);
  }
}

final desktopCloseBehaviorControllerProvider =
    AsyncNotifierProvider<DesktopCloseBehaviorController, DesktopCloseBehavior>(
  DesktopCloseBehaviorController.new,
);
