import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/lifecycle/async_disposal_registry.dart';
import '../../core/models/track.dart';
import '../../core/services/media_artwork_source.dart';
import '../../core/services/notifications/desktop_notifier.dart';
import '../../core/services/notifications/now_playing_notification.dart';
import '../../core/services/notifications/track_change_notifier.dart';
import '../../data/repositories/desktop_notifier_provider.dart';
import '../../data/repositories/host_platform_provider.dart';
import '../settings/desktop/track_change_notifications_controller.dart';
import 'media_artwork_providers.dart';
import 'player_providers.dart';

/// Announces track changes on the desktop (issue #400), or null where there is
/// nothing to announce them through.
///
/// **Instantiated at bootstrap, not by the UI.** The controller's state stream
/// is a plain broadcast stream with no replay, so an observer only sees what
/// happens after it subscribes; created lazily by a settings page nobody
/// opened, it would notify nothing. `bootstrapApplication` reads this
/// alongside the other side-effect-only services, the same way it reads the
/// recent-playback recorder.
///
/// Null (no observer, no subscription, nothing) off the desktop and wherever
/// the notification seam reports itself unsupported, which is every platform
/// but Linux. Android's per-track notification is the media session's, drawn
/// by the system, and nothing here changes it.
///
/// The preference is read *live* on each candidate rather than captured, so
/// switching notifications off in Settings silences the next track change at
/// once. Creating the controller here is deliberate too: it starts the stored
/// value loading at bootstrap, so the first song of the session is already
/// answerable instead of arriving before the answer does.
final trackChangeNotifierProvider = Provider<TrackChangeNotifier?>((ref) {
  if (!ref.watch(hostPlatformProvider).isDesktop) return null;

  final DesktopNotifier notifier = ref.read(desktopNotifierProvider);
  if (!notifier.isSupported) return null;

  final MediaArtworkSource artwork = ref.read(mediaArtworkCacheProvider);
  ref.read(trackChangeNotificationsControllerProvider);

  final TrackChangeNotifier service = TrackChangeNotifier(
    states: ref.read(playbackControllerProvider).stateStream,
    notifier: notifier,
    enabled: () =>
        ref.read(trackChangeNotificationsControllerProvider).valueOrNull ??
        false,
    build: (Track track) => nowPlayingNotification(track, artwork: artwork),
  );
  service.start();
  ref.onDisposeAsync(service.dispose);
  return service;
});
