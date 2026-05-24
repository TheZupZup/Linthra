import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/playback_state.dart';
import '../../core/services/just_audio_playback_controller.dart';
import '../../core/services/local_playable_uri_resolver.dart';
import '../../core/services/offline_first_playable_uri_resolver.dart';
import '../../core/services/playable_uri_resolver.dart';
import '../../core/services/playback_controller.dart';
import '../../core/services/routing_playable_uri_resolver.dart';
import '../../core/sources/jellyfin/jellyfin_playable_uri_resolver.dart';
import '../../data/repositories/download_repository_provider.dart';
import '../settings/jellyfin/jellyfin_settings_controller.dart';

/// Composes the [PlayableUriResolver] the controller resolves tracks through.
///
/// Offline first: a downloaded track resolves to its cached `file://` copy
/// before anything else. On a cache miss it falls through to the source router,
/// which mints an authenticated Jellyfin stream URL at play time (reading the
/// live signed-in source, so sign-in/out is picked up without a rebuild) and
/// sends everything else to the on-device resolver. The UI and controller
/// depend only on the [PlayableUriResolver] interface, never on Jellyfin, the
/// cache, or HTTP.
final playableUriResolverProvider = Provider<PlayableUriResolver>((ref) {
  final fallback = RoutingPlayableUriResolver(<PlayableUriResolver>[
    JellyfinPlayableUriResolver(() => ref.read(jellyfinMusicSourceProvider)),
    const LocalPlayableUriResolver(),
  ]);
  return OfflineFirstPlayableUriResolver(
    locator: ref.watch(cachedTrackLocatorProvider),
    fallback: fallback,
  );
});

/// The single [PlaybackController] the app drives playback through.
///
/// Defaults to the `just_audio`-backed implementation, wired with the routing
/// resolver above. Tests override it with a fake so playback can be exercised
/// without the audio plugin. Disposed with the provider scope (i.e. on app
/// shutdown) so native resources are released.
///
/// Lifecycle: this is pinned for the whole app session. It reads its resolver
/// once with [Ref.read] rather than [Ref.watch], so a rebuild of the resolver,
/// the offline-cache locator, or the download stores can never tear the
/// controller down. That matters because the live `AudioPlayer` and the
/// `audio_service` media session are both bound to *this* instance: recreating
/// it mid-playback would dispose the player (cutting the music) and leave the
/// notification mirroring a dead controller. Navigating between tabs and
/// changing settings touch none of that, so playback survives them. The
/// resolver still reads the live signed-in Jellyfin source lazily at play time,
/// so sign-in/out is picked up without rebuilding the controller.
final playbackControllerProvider = Provider<PlaybackController>((ref) {
  final controller = JustAudioPlaybackController(
    resolver: ref.read(playableUriResolverProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});

/// Streams [PlaybackState] for the UI. Until the first event arrives, callers
/// fall back to the controller's synchronous [PlaybackController.state].
final playbackStateProvider = StreamProvider<PlaybackState>((ref) {
  final controller = ref.watch(playbackControllerProvider);
  return controller.stateStream;
});
