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
import '../../core/services/routing_playable_uri_resolver.dart';
import '../../core/services/smart_precache_service.dart';
import '../../core/services/stream_preload_service.dart';
import '../../core/services/stream_preloading_resolver.dart';
import '../../core/sources/jellyfin/jellyfin_playable_uri_resolver.dart';
import '../../core/sources/subsonic/subsonic_playable_uri_resolver.dart';
import '../../data/repositories/download_repository_provider.dart';
import '../settings/jellyfin/jellyfin_settings_controller.dart';
import '../settings/subsonic/subsonic_settings_controller.dart';
import 'cast/cast_providers.dart';

/// The source router wrapped in the stream-preloading decorator.
///
/// Pinned as its own provider so the controller's resolver **and** the
/// [streamPreloadServiceProvider] share the *same* in-memory preload cache: the
/// service warms the next remote track's stream URL here, and the controller
/// consumes it on the next play. It only ever holds short-lived remote URLs in
/// memory — never the offline cache. Depends only on lazily-read source getters,
/// so signing in/out is picked up without rebuilding (keeping the instance, and
/// its cache, stable for the session).
final streamPreloadingResolverProvider =
    Provider<StreamPreloadingResolver>((ref) {
  return StreamPreloadingResolver(
    RoutingPlayableUriResolver(<PlayableUriResolver>[
      JellyfinPlayableUriResolver(() => ref.read(jellyfinMusicSourceProvider)),
      SubsonicPlayableUriResolver(() => ref.read(subsonicMusicSourceProvider)),
      const LocalPlayableUriResolver(),
    ]),
  );
});

/// Composes the [PlayableUriResolver] the controller resolves tracks through.
///
/// Offline first: a downloaded track resolves to its cached `file://` copy
/// before anything else. On a cache miss it falls through to the
/// stream-preloading source router, which serves a pre-warmed URL when one is
/// ready or mints a fresh authenticated stream URL at play time (reading the
/// live signed-in source, so sign-in/out is picked up without a rebuild). The UI
/// and controller depend only on the [PlayableUriResolver] interface, never on
/// Jellyfin, the cache, or HTTP.
final playableUriResolverProvider = Provider<PlayableUriResolver>((ref) {
  return OfflineFirstPlayableUriResolver(
    locator: ref.watch(cachedTrackLocatorProvider),
    fallback: ref.watch(streamPreloadingResolverProvider),
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

/// Smart pre-cache: warms the next few queued tracks into the offline cache as
/// playback moves, so upcoming songs play instantly and offline (bounded by the
/// cache limit, honouring "Allow mobile data" and the user's smart-pre-cache
/// on/off and count; calm under repeat-one).
///
/// Pinned for the session like the controller: it reads the controller's state
/// stream and the cache/prefs seams once with [Ref.read], so a rebuild of the
/// download stores or preferences can't tear it down mid-session. It does its
/// work as a side effect of listening, so `main` instantiates it once after
/// startup; nothing in the UI reads its value.
final smartPrecacheServiceProvider = Provider<SmartPrecacheService>((ref) {
  final service = SmartPrecacheService(
    playbackStates: ref.read(playbackControllerProvider).stateStream,
    prefetcher: ref.read(trackPrefetcherProvider),
    preferences: ref.read(downloadPreferencesProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// Stream preload: as playback advances, warms the **immediate next** remote
/// track's stream URL into the shared in-memory cache so a skip starts faster.
///
/// This is **not** the offline cache — it never writes bytes to disk, never
/// marks a track as downloaded, and never blocks the current track (best-effort,
/// one warm at a time, calm under repeat-one). It complements smart pre-cache
/// (which warms upcoming tracks to *disk*). Pinned for the session like the
/// controller; reads its seams once with [Ref.read]. It does its work as a side
/// effect of listening, so `main` instantiates it once after startup; nothing in
/// the UI reads its value.
final streamPreloadServiceProvider = Provider<StreamPreloadService>((ref) {
  final service = StreamPreloadService(
    playbackStates: ref.read(playbackControllerProvider).stateStream,
    preloader: ref.read(streamPreloadingResolverProvider),
  );
  ref.onDispose(service.dispose);
  return service;
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
