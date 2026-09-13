import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/repositories/desktop_notification_preferences_provider.dart';

/// Owns the "Notify me when the track changes" choice: loads the persisted
/// value and writes changes back through [DesktopNotificationPreferences].
///
/// Only the *stored choice* lives here. What it means (which transitions
/// count, what may be said, and how often) is `TrackChangeNotifier`'s and
/// `nowPlayingNotification`'s decision.
///
/// Read live by the notification path on every candidate track change, so
/// turning this off silences the very next one, including one already waiting
/// out the rate limit.
class TrackChangeNotificationsController extends AsyncNotifier<bool> {
  @override
  Future<bool> build() {
    return ref
        .read(desktopNotificationPreferencesProvider)
        .trackChangeNotifications();
  }

  Future<void> setEnabled(bool enabled) async {
    final AsyncValue<bool> previous = state;
    // Applied before the write, not after it. The notification path reads this
    // live on every track change, and persisting is a platform round-trip: in
    // between, a track change would still see the old answer, so turning
    // notifications off could let one more notification through and turning
    // them on could mark the next track as already seen.
    state = AsyncData<bool>(enabled);
    try {
      await ref
          .read(desktopNotificationPreferencesProvider)
          .setTrackChangeNotifications(enabled);
    } catch (_) {
      // The choice did not reach storage, so stop claiming it: a switch left
      // on would disagree with the next launch. Restored only if nothing has
      // since been chosen on top of it, so a second tap is never undone by the
      // first tap's failure.
      if (state.valueOrNull == enabled) state = previous;
    }
  }
}

final trackChangeNotificationsControllerProvider =
    AsyncNotifierProvider<TrackChangeNotificationsController, bool>(
  TrackChangeNotificationsController.new,
);
