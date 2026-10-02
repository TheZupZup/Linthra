import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/repositories/playback_preferences.dart';
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

  /// The saves still to come, chained so they run one at a time.
  Future<void> _saving = Future<void>.value();

  /// How many choices have been made, so a failed save can tell whether a
  /// newer choice has come along since.
  int _choices = 0;

  /// Switching it off takes effect at once, then saves: a countdown already
  /// running must stop the moment the listener says so, not when a slow write
  /// comes back, by which time the skip may have happened. Switching it on
  /// takes effect once it is saved: until then nothing may skip on its
  /// strength (a held countdown included), since a save that fails would
  /// leave a song changed on a choice that wasn't kept. Off is the safe side
  /// to be on while a save runs.
  ///
  /// Saves run one at a time, in the order the choices were made, so two
  /// quick taps on the switch store the last one, whichever write is slower.
  /// If the save of the latest choice fails, the choice goes back to what is
  /// actually stored (and the save's error is rethrown), so what playback
  /// follows never disagrees with it. When even that can't be read, it fails
  /// closed: off, which stops on a failed track rather than changing songs.
  /// An older choice that failed leaves things to the newer one, whose save
  /// comes after it.
  Future<void> setEnabled(bool value) async {
    final int choice = ++_choices;
    if (!value) state = const AsyncData<bool?>(false);
    final PlaybackPreferences preferences =
        ref.read(playbackPreferencesProvider);
    final Future<void> save =
        _saving.then((_) => preferences.setAutoSkipUnplayable(value));
    _saving = save.then((_) {}, onError: (Object _) {});
    try {
      await save;
      if (value && choice == _choices) state = const AsyncData<bool?>(true);
    } catch (_) {
      if (choice == _choices) {
        bool? stored;
        try {
          stored = await preferences.autoSkipUnplayable();
        } catch (_) {
          stored = false;
        }
        if (choice == _choices) state = AsyncData<bool?>(stored);
      }
      rethrow;
    }
  }
}

final autoSkipControllerProvider =
    AsyncNotifierProvider<AutoSkipController, bool?>(
  AutoSkipController.new,
);
