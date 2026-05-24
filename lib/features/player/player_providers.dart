import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/playback_state.dart';
import '../../core/services/active_playback_controller.dart';
import '../../core/services/just_audio_playback_controller.dart';
import '../../core/services/local_playable_uri_resolver.dart';
import '../../core/services/local_playback_controller.dart';
import '../../core/services/offline_first_playable_uri_resolver.dart';
import '../../core/services/playable_uri_resolver.dart';
import '../../core/services/playback_controller.dart';
import '../../core/services/playback_preloader.dart';
import '../../core/services/routing_playable_uri_resolver.dart';
import '../../core/sources/jellyfin/jellyfin_playable_uri_resolver.dart';
import '../../data/repositories/download_repository_provider.dart';
import '../settings/jellyfin/jellyfin_settings_controller.dart';
import 'cast/cast_providers.dart';

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
    // On a cache hit, refresh the track's least-recently-used position so
    // eviction keeps what's actually listened to. Read lazily (no build-time
    // dependency on the cache manager) and never awaited — a metadata write
    // must not block or break playback.
    onCacheHit: (trackId) =>
        unawaited(ref.read(offlineCacheManagerProvider).notePlayed(trackId)),
  );
});

/// The on-device audio engine: the `just_audio`-backed [LocalPlaybackController]
/// that owns the queue (current track, up-next, shuffle, repeat) regardless of
/// which output is making sound.
///
/// Lifecycle: pinned for the whole app session. It reads its resolver once with
/// [Ref.read] rather than [Ref.watch], so a rebuild of the resolver, the
/// offline-cache locator, or the download stores can never tear it down — which
/// would dispose the live `AudioPlayer` and cut the music. The resolver still
/// reads the live signed-in Jellyfin source lazily at play time, so sign-in/out
/// is picked up without rebuilding the engine.
final localPlaybackControllerProvider =
    Provider<LocalPlaybackController>((ref) {
  final controller = JustAudioPlaybackController(
    resolver: ref.read(playableUriResolverProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});

/// The single [PlaybackController] the UI drives playback through, routing
/// between the local engine and a cast receiver and exposing one unified
/// [PlaybackState].
///
/// The UI depends only on this — never on `just_audio` or the cast SDK — so when
/// casting is active the now-playing screen, mini-player, and lyrics follow the
/// receiver (position, play-state, duration) while transport commands go to the
/// device that is actually playing. It owns the local↔cast switch, suspending
/// the engine on handoff and resuming it *paused* when a session ends, so the
/// phone never surprise-starts. Tests override it with a fake so playback can be
/// exercised without the audio plugin. Pinned for the session and disposed with
/// the scope (its subscriptions only; the engine and cast service are disposed
/// by their own providers).
final playbackControllerProvider = Provider<PlaybackController>((ref) {
  final controller = ActivePlaybackController(
    local: ref.read(localPlaybackControllerProvider),
    cast: ref.read(castServiceProvider),
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

/// Warms the next few queued tracks into the offline cache as playback moves,
/// so upcoming songs play instantly and offline (bounded by the cache limit,
/// and honouring "Wi-Fi only" / the preload preference).
///
/// Pinned for the session like the controller: it reads the controller's state
/// stream and the cache/prefs seams once with [Ref.read], so a rebuild of the
/// download stores or preferences can't tear it down mid-session. It does its
/// work as a side effect of listening, so `main` instantiates it once after
/// startup; nothing in the UI reads its value.
final playbackPreloaderProvider = Provider<PlaybackPreloader>((ref) {
  final preloader = PlaybackPreloader(
    playbackStates: ref.read(playbackControllerProvider).stateStream,
    prefetcher: ref.read(trackPrefetcherProvider),
    preferences: ref.read(downloadPreferencesProvider),
  );
  ref.onDispose(preloader.dispose);
  return preloader;
});

/// Production binding: lets the cache eviction policy see the currently playing
/// track so it's never deleted to make room. The closure reads the controller's
/// latest state lazily at eviction time, so applying this override doesn't tie
/// the download repository to the controller's lifecycle. Applied in `main`;
/// tests keep the data-layer default (nothing playing).
final currentlyPlayingTrackIdOverride =
    currentlyPlayingTrackIdProvider.overrideWith(
  (ref) => () => ref.read(playbackControllerProvider).state.currentTrack?.id,
);
