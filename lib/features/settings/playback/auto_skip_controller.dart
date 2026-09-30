import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/repositories/playback_preferences_provider.dart';

/// Owns the "Automatically skip tracks that can't play" choice: loads the
/// persisted value and writes changes back through [PlaybackPreferences].
///
/// `null` means the listener hasn't chosen yet, which playback treats as off
/// and which is the one case where the player explains the feature (once, the
/// first time a track can't be recovered). The setting switch and that
/// explanation write the same preference through here, so there is a single
/// source of truth. Playback reads it through the app's lifecycle wiring and
/// enforces it in the controller; no screen decides when to skip.
class AutoSkipController extends AsyncNotifier<bool?> {
  @override
  Future<bool?> build() {
    return ref.read(playbackPreferencesProvider).autoSkipUnplayable();
  }

  Future<void> setEnabled(bool value) async {
    await ref.read(playbackPreferencesProvider).setAutoSkipUnplayable(value);
    state = AsyncData<bool?>(value);
  }
}

final autoSkipControllerProvider =
    AsyncNotifierProvider<AutoSkipController, bool?>(
  AutoSkipController.new,
);
