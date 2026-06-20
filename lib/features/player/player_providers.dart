import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/playback_state.dart';
import '../../core/services/active_playback_controller.dart';
import '../../core/services/just_audio_playback_controller.dart';
import '../../core/services/local_playable_uri_resolver.dart';
import '../../core/services/local_playback_controller.dart';
import '../../core/services/offline_first_playable_uri_resolver.dart';
import '../../core/services/playable_uri_resolver.dart';
import '../../core/services/playback_candidate_source.dart';
import '../../core/services/playback_controller.dart';
import '../../core/services/playback_reporting_service.dart';
import '../../core/services/remote_cache/remote_cache_resolver.dart';
import '../../core/services/remote_cache/remote_playback_cache.dart';
import '../../core/services/remote_cache/remote_stream_prebufferer.dart';
import '../../core/services/remote_control_activator.dart';
import '../../core/services/remote_control_receiver.dart';
import '../../core/services/remote_control_service.dart';
import '../../core/services/remote_prebuffer_service.dart';
import '../../core/services/routing_playable_uri_resolver.dart';
import '../../core/services/routing_server_playback_reporter.dart';
import '../../core/services/server_playback_reporter.dart';
import '../../core/services/smart_precache_service.dart';
import '../../core/sources/jellyfin/jellyfin_playable_uri_resolver.dart';
import '../../core/sources/jellyfin/jellyfin_playback_reporter.dart';
import '../../core/sources/jellyfin/jellyfin_remote_control_receiver.dart';
import '../../core/sources/jellyfin/jellyfin_track_mapper.dart';
import '../../core/sources/plex/plex_playable_uri_resolver.dart';
import '../../core/sources/plex/plex_playback_reporter.dart';
import '../../core/sources/subsonic/subsonic_playable_uri_resolver.dart';
import '../../core/sources/subsonic/subsonic_playback_reporter.dart';
import '../../data/repositories/download_repository_provider.dart';
import '../../data/repositories/play_history_repository_provider.dart';
import '../../data/repositories/remote_cache_index_provider.dart';
import '../settings/jellyfin/jellyfin_settings_controller.dart';
import '../settings/jellyfin/jellyfin_settings_providers.dart';
import '../settings/plex/plex_settings_controller.dart';
import '../settings/plex/plex_settings_providers.dart';
import '../settings/subsonic/subsonic_settings_controller.dart';
import '../settings/subsonic/subsonic_settings_providers.dart';
import 'cast/cast_providers.dart';
import 'now_playing.dart';

/// The shared in-memory store of prebuffered remote stream URLs.
///
/// Pinned for the session so the read side ([remoteCacheResolverProvider]) and
/// the write side ([remoteStreamPrebuffererProvider]) share the *same* cache:
/// the prebuffer service warms upcoming remote URLs here and the controller's
/// resolver consumes them on the next play. It only ever holds short-lived
/// remote URLs in memory — never the offline cache, and never persisted.
final remotePlaybackCacheProvider = Provider<RemotePlaybackCache>((ref) {
  return RemotePlaybackCache();
});

/// The source router: Jellyfin, Subsonic, Plex, then the on-device catch-all.
///
/// Depends only on lazily-read source getters, so signing in/out is picked up
/// without rebuilding (keeping the instance stable for the session). Shared by
/// the cache resolver (which reads through it on a miss) and the prebufferer
/// (which warms through it), so both mint URLs exactly the same way.
final remoteSourceRouterProvider = Provider<RoutingPlayableUriResolver>((ref) {
  return RoutingPlayableUriResolver(<PlayableUriResolver>[
    JellyfinPlayableUriResolver(() => ref.read(jellyfinMusicSourceProvider)),
    SubsonicPlayableUriResolver(() => ref.read(subsonicMusicSourceProvider)),
    // With no Plex session the source provider is null and a plex: track
    // resolves to a friendly "not signed in" rather than falling through
    // as unplayable.
    PlexPlayableUriResolver(() => ref.read(plexMusicSourceProvider)),
    const LocalPlayableUriResolver(),
  ]);
});

/// The read side of the remote playback cache: serves a prebuffered stream URL
/// when one is fresh (consume-on-read) and otherwise mints a fresh one through
/// the source router. Shares the session cache with the prebufferer.
final remoteCacheResolverProvider = Provider<RemoteCacheResolver>((ref) {
  return RemoteCacheResolver(
    inner: ref.watch(remoteSourceRouterProvider),
    cache: ref.watch(remotePlaybackCacheProvider),
  );
});

/// The write side: aggressively warms the current and next remote stream URLs
/// into the shared cache. Driven by [remotePrebufferServiceProvider].
final remoteStreamPrebuffererProvider =
    Provider<RemoteStreamPrebufferer>((ref) {
  return RemoteStreamPrebufferer(
    resolver: ref.watch(remoteSourceRouterProvider),
    cache: ref.watch(remotePlaybackCacheProvider),
    // Persist each warm's credential-free key into the durable index so the
    // cache's knowledge survives a restart. Best-effort and never on the
    // playback path; only the opaque key is stored, never the stream URL.
    index: ref.watch(remoteCacheIndexProvider),
  );
});

/// Composes the [PlayableUriResolver] the controller resolves tracks through.
///
/// Offline first: a downloaded track resolves to its cached `file://` copy
/// before anything else. On a cache miss it falls through to the remote cache
/// resolver, which serves a pre-warmed URL when one is ready or mints a fresh
/// authenticated stream URL at play time (reading the live signed-in source, so
/// sign-in/out is picked up without a rebuild). The UI and controller depend
/// only on the [PlayableUriResolver] interface, never on Jellyfin, the cache, or
/// HTTP.
final playableUriResolverProvider = Provider<PlayableUriResolver>((ref) {
  return OfflineFirstPlayableUriResolver(
    locator: ref.watch(cachedTrackLocatorProvider),
    fallback: ref.watch(remoteCacheResolverProvider),
    // On a cache hit, refresh the track's least-recently-used position so
    // eviction keeps what's actually listened to. Read lazily (no build-time
    // dependency on the cache manager) and never awaited — a metadata write
    // must not block or break playback.
    onCacheHit: (track) =>
        unawaited(ref.read(offlineCacheManagerProvider).notePlayed(track)),
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
/// Supplies a track's ordered source candidates to the playback controller for
/// runtime fallback. The default has **no** fallback (each track is its own only
/// candidate), so playback is unchanged until a real, library-backed source is
/// wired in. `main` overrides this with [playbackCandidateSourceOverride] so a
/// failed preferred copy can fall back to another copy of the same song.
final playbackCandidateSourceProvider = Provider<PlaybackCandidateSource>(
  (ref) => const NoFallbackCandidateSource(),
);

final localPlaybackControllerProvider =
    Provider<LocalPlaybackController>((ref) {
  final controller = JustAudioPlaybackController(
    resolver: ref.read(playableUriResolverProvider),
    // Read once at construction; the candidate source itself reads the live
    // library lazily at play time, so the session-pinned engine still sees a
    // fresh catalog (and default-source change) without being rebuilt.
    candidates: ref.read(playbackCandidateSourceProvider),
    // When a track's offline-cache file won't open (corrupt, or reclaimed after
    // the existence check), fall back to streaming the *same* track — this
    // resolver resolves past the offline cache (the offline-first resolver's own
    // fallback), so even a single-source cached track recovers to its live
    // stream rather than erroring.
    streamingFallbackResolver: ref.read(remoteCacheResolverProvider),
    // Record a completed play when a track reaches its end. Read lazily at
    // completion time (not watched), so the play-history repository never ties
    // into the engine's lifecycle. Only the track id is recorded; it stays
    // on-device. Casting suspends the engine, so cast plays aren't counted.
    onTrackCompleted: (track) => unawaited(
        ref.read(playHistoryRepositoryProvider).recordCompletion(track)),
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

/// Remote prebuffer: as playback advances, warms the **current** remote track
/// and the **next** queue item's stream URL into the shared in-memory cache so a
/// skip — or the natural roll into the next track — starts faster.
///
/// This is **not** the offline cache — it never writes bytes to disk, never
/// marks a track as downloaded, and never blocks the current track (best-effort,
/// one pass at a time, calm under repeat-one). It complements smart pre-cache
/// (which warms upcoming tracks to *disk*). Pinned for the session like the
/// controller; reads its seams once with [Ref.read]. It does its work as a side
/// effect of listening, so `main` instantiates it once after startup; nothing in
/// the UI reads its value.
final remotePrebufferServiceProvider = Provider<RemotePrebufferService>((ref) {
  final service = RemotePrebufferService(
    playbackStates: ref.read(playbackControllerProvider).stateStream,
    prebufferer: ref.read(remoteStreamPrebuffererProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// The reporter playback lifecycle events route through: Plex for
/// `plex:<ratingKey>` tracks (PMS timelines), Jellyfin for `jellyfin:<itemId>`
/// tracks (play-session reports), Subsonic for `subsonic:<id>` tracks
/// (now-playing + scrobble), and nothing for local files — a track only ever
/// reaches the reporter that claims its uri, so one provider's playback can
/// never trigger another provider's call.
///
/// Each reporter reads its session and client through lazy getters — the
/// same shape the source router above uses — so signing in/out, and the
/// client/device identity persisted at sign-in (which the server keys the
/// player session on), are picked up live without rebuilding the reporter or
/// the session-pinned reporting service that holds it.
final serverPlaybackReporterProvider = Provider<ServerPlaybackReporter>((ref) {
  return RoutingServerPlaybackReporter(<ServerPlaybackReporter>[
    PlexPlaybackReporter(
      session: () => ref.read(plexMusicSourceProvider)?.session,
      client: () => ref.read(plexClientProvider),
    ),
    JellyfinPlaybackReporter(
      session: () => ref.read(jellyfinMusicSourceProvider)?.session,
      client: () => ref.read(jellyfinClientProvider),
    ),
    SubsonicPlaybackReporter(
      session: () => ref.read(subsonicMusicSourceProvider)?.session,
      client: () => ref.read(subsonicClientProvider),
    ),
  ]);
});

/// Playback reporting: mirrors live playback onto the server that owns the
/// playing track (Plex, Jellyfin, or Subsonic/Navidrome), so the user's own
/// dashboard shows Linthra as an active player — started/paused/resumed/
/// stopped immediately, progress on a throttled heartbeat (each provider
/// reporter maps those onto what its protocol supports).
///
/// Pinned for the session like smart pre-cache and remote prebuffer: it reads
/// the controller's state stream and the reporter once with [Ref.read], does
/// its work as a side effect of listening (best-effort, off the playback
/// path, failures swallowed), and `main` instantiates it once after startup;
/// nothing in the UI reads its value.
final playbackReportingServiceProvider =
    Provider<PlaybackReportingService>((ref) {
  final service = PlaybackReportingService(
    playbackStates: ref.read(playbackControllerProvider).stateStream,
    reporter: ref.read(serverPlaybackReporterProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// The remote-control receiver — the inverse of the playback reporter. A
/// Jellyfin control-socket receiver today; reads the live Jellyfin
/// session/client lazily, so sign-in/out is picked up without rebuilding.
/// Pinned for the session: its transport is opened/closed by
/// [remoteControlActivatorProvider] in step with playback, and finally disposed
/// with the scope.
final remoteControlReceiverProvider = Provider<RemoteControlReceiver>((ref) {
  final receiver = JellyfinRemoteControlReceiver(
    session: () => ref.read(jellyfinMusicSourceProvider)?.session,
    client: () => ref.read(jellyfinClientProvider),
  );
  ref.onDispose(receiver.dispose);
  return receiver;
});

/// Applies remote commands to the active [PlaybackController], so a Jellyfin
/// remote's play/pause/skip/seek drives playback exactly like an on-screen tap
/// — flowing through cast routing, the media session, and reporting alike.
/// Side-effect-only; `main` instantiates it once after startup.
final remoteControlServiceProvider = Provider<RemoteControlService>((ref) {
  final service = RemoteControlService(
    receiver: ref.read(remoteControlReceiverProvider),
    controller: ref.read(playbackControllerProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// Whether [state] is a Jellyfin track actively playing or paused — the window
/// in which Linthra connects the control socket to accept remote commands.
/// Keeping the socket to exactly this window (rather than the whole signed-in
/// session) is what keeps remote control off the "no background keep-alives"
/// budget.
bool _isJellyfinControllable(PlaybackState state) {
  final track = state.currentTrack;
  if (track == null) return false;
  if (!track.uri.startsWith(JellyfinTrackMapper.uriScheme)) return false;
  final status = state.status;
  return status == PlaybackStatus.playing || status == PlaybackStatus.paused;
}

/// Connects the remote-control transport only while a controllable Jellyfin
/// track is the active playback session, so there is no persistent background
/// socket (keeping Linthra's "event-driven, never polled" stance). Reads the
/// controller's state stream once; side-effect-only, instantiated by `main`.
final remoteControlActivatorProvider = Provider<RemoteControlActivator>((ref) {
  final activator = RemoteControlActivator(
    receiver: ref.read(remoteControlReceiverProvider),
    playbackStates: ref.read(playbackControllerProvider).stateStream,
    isControllable: _isJellyfinControllable,
  );
  ref.onDispose(activator.dispose);
  return activator;
});

/// Production binding: lets the cache eviction policy see the currently playing
/// track so it's never deleted to make room. Passes the whole [Track] so the
/// policy protects exactly that provider's copy by its provider-aware key. The
/// closure reads the controller's latest state lazily at eviction time, so
/// applying this override doesn't tie the download repository to the
/// controller's lifecycle. Applied in `main`; tests keep the data-layer default
/// (nothing playing).
final currentlyPlayingTrackOverride =
    currentlyPlayingTrackProvider.overrideWith(
  (ref) => () => ref.read(playbackControllerProvider).state.currentTrack,
);

/// Production binding: drives the now-playing indicator on every track row from
/// the live [PlaybackState]. Selected down to `(current track, isPlaying)` so it
/// updates only on a track change or a play/pause flip — never on a position
/// tick — keeping the indicator's rebuilds rare. Applied in `main`; tests keep
/// the inert default ([nowPlayingProvider] — nothing playing) unless they
/// override it, so no row animates and no audio plugin is touched in a test.
final nowPlayingOverride = nowPlayingProvider.overrideWith((ref) {
  final controller = ref.watch(playbackControllerProvider);
  return ref.watch(
    playbackStateProvider.select((async) {
      final PlaybackState state = async.valueOrNull ?? controller.state;
      return NowPlaying(
        currentTrack: state.currentTrack,
        isPlaying: state.isPlaying,
      );
    }),
  );
});
