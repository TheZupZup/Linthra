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
    await ref
        .read(desktopNotificationPreferencesProvider)
        .setTrackChangeNotifications(enabled);
    state = AsyncData<bool>(enabled);
  }
}

final trackChangeNotificationsControllerProvider =
    AsyncNotifierProvider<TrackChangeNotificationsController, bool>(
  TrackChangeNotificationsController.new,
);
