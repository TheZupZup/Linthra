import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/lifecycle/async_disposal_registry.dart';
import '../../core/lifecycle/system_sleep_watcher.dart';
import '../../core/models/playback_state.dart';
import '../../core/models/subsonic_session.dart';
import '../../core/models/track.dart';
import '../../core/platform/host_platform.dart';
import '../../core/repositories/download_store.dart';
import '../../core/services/active_playback_controller.dart';
import '../../core/services/just_audio_playback_controller.dart';
import '../../core/services/linux_playback_controller.dart';
import '../../core/services/local_playable_uri_resolver.dart';
import '../../core/services/local_playback_controller.dart';
import '../../core/services/offline_copy_origins.dart';
import '../../core/services/offline_first_playable_uri_resolver.dart';
import '../../core/services/platform_playback_support.dart';
import '../../core/services/playable_uri_resolver.dart';
import '../../core/services/playback_candidate_source.dart';
import '../../core/services/playback_controller.dart';
import '../../core/services/playback_recovery_policy.dart';
import '../../core/services/playback_reporting_service.dart';
import '../../core/services/provider_reachability.dart';
import '../../core/services/reachability.dart';
import '../../core/services/reachability_aware_playable_uri_resolver.dart';
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
import '../../core/services/unsupported_playback_controller.dart';
import '../../core/sources/jellyfin/jellyfin_account_fingerprint.dart';
import '../../core/sources/jellyfin/jellyfin_playable_uri_resolver.dart';
import '../../core/sources/jellyfin/jellyfin_playback_reporter.dart';
import '../../core/sources/jellyfin/jellyfin_remote_control_receiver.dart';
import '../../core/sources/jellyfin/jellyfin_track_mapper.dart';
import '../../core/sources/plex/plex_playable_uri_resolver.dart';
import '../../core/sources/plex/plex_playback_reporter.dart';
import '../../core/sources/plex/plex_session_fingerprint.dart';
import '../../core/sources/plex/plex_track_mapper.dart';
import '../../core/sources/subsonic/subsonic_account_fingerprint.dart';
import '../../core/sources/subsonic/subsonic_music_source.dart';
import '../../core/sources/subsonic/subsonic_playable_uri_resolver.dart';
import '../../core/sources/subsonic/subsonic_playback_reporter.dart';
import '../../core/sources/subsonic/subsonic_track_mapper.dart';
import '../../data/repositories/download_repository_provider.dart';
import '../../data/repositories/host_platform_provider.dart';
import '../../data/repositories/play_history_repository_provider.dart';
import '../../data/repositories/remote_cache_index_provider.dart';
import '../settings/jellyfin/jellyfin_availability_controller.dart';
import '../settings/jellyfin/jellyfin_settings_controller.dart';
import '../settings/jellyfin/jellyfin_settings_providers.dart';
import '../settings/local_network/local_network_providers.dart';
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

/// A brief, per-provider memory of reachability outcomes, shared for the whole
/// session so the play path and the background prebuffer agree on whether a
/// server is currently reachable.
///
/// Pinned (not rebuilt on sign-in/out) so a recorded outage survives across the
/// burst of tracks it's meant to cover; its own short TTL ages entries out, and
/// the per-provider keys mean signing out of one provider can't strand another.
final providerReachabilityProvider = Provider<ProviderReachability>((ref) {
  return CachingProviderReachability();
});

/// The source router: Jellyfin, Subsonic, Plex, then the on-device catch-all.
///
/// Depends only on lazily-read source getters, so signing in/out is picked up
/// without rebuilding (keeping the instance stable for the session). Shared by
/// the cache resolver (which reads through it on a miss) and the prebufferer
/// (which warms through it), so both mint URLs exactly the same way.
///
/// Each remote resolver is wrapped in a [ReachabilityAwarePlayableUriResolver]
/// so a server that's offline fails fast (and the player falls back to a cached
/// copy or another provider promptly) instead of re-paying a connect timeout for
/// every track. The wrapper keys on the **provider + signed-in server/account**
/// (a non-secret fingerprint), not just the provider name: a Jellyfin/Plex/
/// Subsonic memory stays isolated from the other providers, *and* an outage
/// recorded for one server never fast-fails a different server the user signs
/// into — the key changes, so the new server is probed fresh rather than
/// inheriting the old one's stale "offline". A signed-out provider has no key,
/// so it's never cached. The on-device resolver is never wrapped — a local file
/// doesn't go offline.
final remoteSourceRouterProvider = Provider<RoutingPlayableUriResolver>((ref) {
  PlayableUriResolver reachabilityAware(
    PlayableUriResolver inner,
    String? Function() providerKey, {
    required String? Function() serverUrl,
    void Function(ReachabilityStatus status)? onReachabilityObserved,
  }) {
    return ReachabilityAwarePlayableUriResolver(
      inner: inner,
      providerKey: providerKey,
      reachability: ref.read(providerReachabilityProvider),
      connectivity: ref.read(connectivityServiceProvider),
      onReachabilityObserved: onReachabilityObserved,
      localNetwork: ref.read(localNetworkAccessProvider),
      serverUri: () {
        final String? url = serverUrl();
        return url == null ? null : Uri.tryParse(url);
      },
    );
  }

  return RoutingPlayableUriResolver(<PlayableUriResolver>[
    reachabilityAware(
      JellyfinPlayableUriResolver(() => ref.read(jellyfinMusicSourceProvider)),
      () => _jellyfinSignInKey(ref),
      serverUrl: () => ref.read(jellyfinMusicSourceProvider)?.session.baseUrl,
      // Let the library learn from what the player just found out: the first
      // track that can't reach the server flips Jellyfin to unreachable (and the
      // first that succeeds flips it back) without waiting for the background
      // poll. Purely a visibility signal — see
      // [JellyfinAvailabilityController.noteReachability]; no catalog row,
      // download, playlist or session is touched by it.
      onReachabilityObserved: (ReachabilityStatus status) => ref
          .read(jellyfinAvailabilityProvider.notifier)
          .noteReachability(status),
    ),
    reachabilityAware(
      SubsonicPlayableUriResolver(() => ref.read(subsonicMusicSourceProvider)),
      () => _subsonicAccountKey(ref),
      serverUrl: () => ref.read(subsonicMusicSourceProvider)?.session.baseUrl,
    ),
    // With no Plex session the source provider is null and a plex: track
    // resolves to a friendly "not signed in" rather than falling through
    // as unplayable.
    reachabilityAware(
      PlexPlayableUriResolver(() => ref.read(plexMusicSourceProvider)),
      () => _plexAccountKey(ref),
      serverUrl: () => ref.read(plexMusicSourceProvider)?.session.baseUrl,
    ),
    LocalPlayableUriResolver(presence: ref.read(localFilePresenceProvider)),
  ]);
});

/// The signed-in Jellyfin server + account as a non-secret key, or `null` when
/// signed out. What smart pre-cache, downloads and warmed stream URLs are bound
/// to (Plex aside: see [_accountKeyForTrack]); the reachability memory uses the
/// narrower [_jellyfinSignInKey].
String? _jellyfinAccountKey(Ref ref) {
  final source = ref.read(jellyfinMusicSourceProvider);
  return source == null
      ? null
      : 'jellyfin:${jellyfinAccountFingerprint(source.session)}';
}

/// [_jellyfinAccountKey] narrowed to the sign-in: signing back in to the same
/// account mints a new token. What an attempt made with the previous one found
/// (a token the server rejected, a connection that died with it) says nothing
/// about the session signed in now, so it must neither be reported to the
/// library's availability nor fast-fail the new session. The reachability
/// memory and its observer are keyed by this; everything else stays bound to
/// the account.
String? _jellyfinSignInKey(Ref ref) {
  final source = ref.read(jellyfinMusicSourceProvider);
  return source == null
      ? null
      : 'jellyfin:${jellyfinAccountFingerprint(source.session)}'
          ':${identityHashCode(source.session)}';
}

String? _subsonicAccountKey(Ref ref) {
  final source = ref.read(subsonicMusicSourceProvider);
  return source == null
      ? null
      : 'subsonic:${subsonicAccountFingerprint(source.session)}';
}

String? _plexAccountKey(Ref ref) {
  final source = ref.read(plexMusicSourceProvider);
  return source == null ? null : 'plex:${source.session.machineIdentifier}';
}

/// The account key for whichever provider owns [track], or `null` for a local
/// track or a provider that is signed out. What smart pre-cache binds a queue
/// to, so it is as narrow as the provider allows: for Plex that includes the
/// Home profile, not just the server.
String? _accountKeyForTrack(Ref ref, Track track) {
  final String uri = track.uri;
  if (uri.startsWith(JellyfinTrackMapper.uriScheme)) {
    return _jellyfinAccountKey(ref);
  }
  if (uri.startsWith(SubsonicTrackMapper.uriScheme)) {
    return _subsonicAccountKey(ref);
  }
  if (uri.startsWith(PlexTrackMapper.uriScheme)) {
    final source = ref.read(plexMusicSourceProvider);
    return source == null
        ? null
        : 'plex:${plexSessionFingerprint(source.session)}';
  }
  return null;
}

/// The seam that answers whether an on-device file is still at the path the
/// catalog holds for it, so a track whose file was moved, deleted or unplugged
/// fails with a message that says so instead of a generic engine error.
///
/// A provider rather than the resolver's own default so a test can drive the
/// vanished-file path (and so a test that isn't about it can say "everything
/// exists") without writing real files.
final localFilePresenceProvider = Provider<LocalFilePresence>((ref) {
  return const IoLocalFilePresence();
});

/// The read side of the remote playback cache: serves a prebuffered stream URL
/// when one is fresh (consume-on-read) and otherwise mints a fresh one through
/// the source router. Shares the session cache with the prebufferer.
final remoteCacheResolverProvider = Provider<RemoteCacheResolver>((ref) {
  return RemoteCacheResolver(
    inner: ref.watch(remoteSourceRouterProvider),
    cache: ref.watch(remotePlaybackCacheProvider),
    // A warmed URL carries the credentials of the account it was minted for:
    // it is only served while that account is still the one signed in. Read
    // live at each play.
    accountScopeOf: (Track track) => _accountKeyForTrack(ref, track),
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
    // Each warm is stamped with the account it was minted for, and dropped
    // if that account signs out or changes while it resolves.
    accountScopeOf: (Track track) => _accountKeyForTrack(ref, track),
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

/// Test seam for Linux's native audio engine.
///
/// Production leaves this null so [LinuxPlaybackController] registers and
/// creates media_kit/libmpv. Tests inject a channel-free [AudioPlayer] fake:
/// `flutter test` intentionally does not assemble the native Linux bundle, so
/// loading libmpv there would make otherwise deterministic unit tests depend on
/// host packages or speakers.
final linuxAudioPlayerProvider = Provider<AudioPlayer?>((ref) => null);

/// Test seam for how the Linux engine notices a system sleep (#799).
///
/// Production leaves this null so [LinuxPlaybackController] watches the real
/// machine's clocks. Tests hand in a watcher whose clocks they move.
final linuxSleepWatcherProvider = Provider<SystemSleepWatcher?>((ref) => null);

final localPlaybackControllerProvider =
    Provider<LocalPlaybackController>((ref) {
  // Platforms without an on-device implementation get the explicit
  // unsupported engine instead. This is the only branch: everything downstream —
  // the routing controller, the queue UI, smart pre-cache, playback reporting —
  // keeps talking to a LocalPlaybackController and is unaware which one it got.
  //
  // Building the `just_audio` controller on such a platform is what has to be
  // avoided, not just calling it: its constructor creates an AudioPlayer, which
  // is the plugin-backed object that does not exist there.
  final HostPlatform host = ref.watch(hostPlatformProvider);
  if (!PlatformPlaybackSupport.hasOnDeviceEngine(host)) {
    final UnsupportedPlaybackController unsupported =
        UnsupportedPlaybackController();
    ref.onDisposeAsync(unsupported.dispose);
    return unsupported;
  }

  final controller = host == HostPlatform.linux
      ? LinuxPlaybackController(
          player: ref.read(linuxAudioPlayerProvider),
          resolver: ref.read(playableUriResolverProvider),
          candidates: ref.read(playbackCandidateSourceProvider),
          streamingFallbackResolver: ref.read(remoteCacheResolverProvider),
          onTrackCompleted: (track) => unawaited(
            ref.read(playHistoryRepositoryProvider).recordCompletion(track),
          ),
          automaticRecovery: ref.read(playbackRecoveryPolicyProvider),
          sleepWatcher: ref.read(linuxSleepWatcherProvider),
        )
      : JustAudioPlaybackController(
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
          automaticRecovery: ref.read(playbackRecoveryPolicyProvider),
        );
  ref.onDisposeAsync(controller.dispose);
  return controller;
});

/// How far the on-device engine goes on its own when a track can't be played:
/// one more try, then along the queue, then a stable error (see
/// [PlaybackRecoveryPolicy]). The same bounds on Android and Linux; a test that
/// wants the historic "wait on the error panel" behavior overrides it with
/// null.
final playbackRecoveryPolicyProvider = Provider<PlaybackRecoveryPolicy?>(
  (ref) => const PlaybackRecoveryPolicy(),
);

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
  ref.onDisposeAsync(controller.dispose);
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
///
/// Network recovery resumes it where the platform reports network changes
/// (Android's channel, the network monitor portal on Linux). Elsewhere the
/// next queue change does.
final smartPrecacheServiceProvider = Provider<SmartPrecacheService>((ref) {
  final bool hasNetworkEvents =
      hostReportsNetworkChanges(ref.read(hostPlatformProvider));
  final service = SmartPrecacheService(
    playbackStates: ref.read(playbackControllerProvider).stateStream,
    prefetcher: ref.read(trackPrefetcherProvider),
    preferences: ref.read(downloadPreferencesProvider),
    networkChanges: hasNetworkEvents
        ? ref.read(connectivityServiceProvider).statusStream
        : null,
    // Read live at each check, so a sign-out or account switch mid-fetch is
    // seen before the bytes are committed.
    sessionScopeOf: (Track track) => _accountKeyForTrack(ref, track),
  );
  ref.onDisposeAsync(service.dispose);
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
  ref.onDisposeAsync(service.dispose);
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
  ref.onDisposeAsync(service.dispose);
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
  // An open connection carries the token of the account it was made for. A
  // sign-out, or a sign-in as someone else, while a Jellyfin track plays moves
  // it to whoever is signed in now, or closes it, so an account that signed
  // out can't go on driving the player.
  ref.listen(
    jellyfinMusicSourceProvider.select((source) => source?.session),
    (_, __) => unawaited(receiver.sessionChanged()),
  );
  ref.onDisposeAsync(receiver.dispose);
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
  ref.onDisposeAsync(service.dispose);
  return service;
});

/// Whether [state] is a Jellyfin track actively playing or paused — the window
/// in which Linthra connects the control socket to accept remote commands.
/// Keeping the socket to exactly this window (rather than the whole signed-in
/// session) is what keeps remote control off the "no background keep-alives"
/// budget.
///
/// A Jellyfin track on its way to sound (loading, re-buffering, reconnecting)
/// is in the window too. Every track change opens with the next track
/// loading, and a socket closed for that stretch dropped whatever the remote
/// sent meanwhile (a Pause right after Next), since the server only delivers
/// over an open socket; it also reconnected on every track.
bool _isJellyfinControllable(PlaybackState state) {
  final track = state.currentTrack;
  if (track == null) return false;
  if (!track.uri.startsWith(JellyfinTrackMapper.uriScheme)) return false;
  final status = state.status;
  return status == PlaybackStatus.playing ||
      status == PlaybackStatus.paused ||
      state.isBusy;
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
  ref.onDisposeAsync(activator.dispose);
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

/// Production binding: binds each download to the account its provider was
/// signed in with when it was asked for, using the same account key as smart
/// pre-cache, so a download waiting for Wi-Fi or a slot is never fetched with
/// another account's session. Read live at each check. Applied in `main`;
/// tests keep the data-layer default (one account).
final downloadAccountScopeOverride = downloadAccountScopeProvider.overrideWith(
  (ref) => (Track track) => _accountKeyForTrack(ref, track),
);

/// Production binding: a Plex or Subsonic download or pre-cache belongs to the
/// server it came from. A Plex ratingKey, or the running number most Subsonic
/// servers give a song (Airsonic, Ampache, gonic's `tr-N`), only means
/// something on the server that issued it, and Navidrome's path-derived ids
/// can name another file on another installation, so a copy from another
/// server, or from before a reinstall, never plays or reads as downloaded for
/// this server's song with the same id. It is kept, and comes back when its
/// server is connected again. Read live; a change of server is announced so
/// the cache re-sorts. Applied in `main`; tests keep the data-layer default
/// (nothing bound).
final offlineCopyOriginsOverride =
    offlineCopyOriginsProvider.overrideWith((ref) {
  final _ServerCopyOrigins origins = _ServerCopyOrigins(
    plex: () => ref.read(plexMusicSourceProvider)?.session.machineIdentifier,
    subsonic: () => _subsonicServerOf(ref.read(subsonicMusicSourceProvider)),
  );
  ref.listen<String?>(
    plexMusicSourceProvider
        .select((source) => source?.session.machineIdentifier),
    (_, __) => origins.changed(),
  );
  ref.listen<String?>(
    subsonicMusicSourceProvider.select(_subsonicServerOf),
    (_, __) => origins.changed(),
  );
  ref.onDispose(origins.close);
  return origins;
});

/// The [subsonicServerFingerprint] of the Subsonic server signed in to, or
/// null while signed out.
String? _subsonicServerOf(SubsonicMusicSource? source) {
  final SubsonicSession? session = source?.session;
  return session == null ? null : subsonicServerFingerprint(session);
}

/// Plex and Subsonic copies, bound to the server connected now.
class _ServerCopyOrigins implements OfflineCopyOrigins {
  _ServerCopyOrigins({
    required String? Function() plex,
    required String? Function() subsonic,
  })  : _plexServer = plex,
        _subsonicServer = subsonic;

  /// The connected Plex server's `machineIdentifier`, or null when signed
  /// out.
  final String? Function() _plexServer;

  /// The connected Subsonic server's fingerprint, or null when signed out.
  final String? Function() _subsonicServer;

  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// How a copy's `sourceType` reads for each provider: its uri scheme,
  /// worked out the same way the cache records it.
  static final String? _plexScheme =
      CachedTrack.schemeOf(PlexTrackMapper.uriScheme);
  static final String? _subsonicScheme =
      CachedTrack.schemeOf(SubsonicTrackMapper.uriScheme);

  @override
  bool binds(String scheme) =>
      scheme == _plexScheme || scheme == _subsonicScheme;

  @override
  String? current(String scheme) {
    if (scheme == _plexScheme) return _plexServer();
    if (scheme == _subsonicScheme) return _subsonicServer();
    return null;
  }

  @override
  Stream<void> get changes => _changes.stream;

  void changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void close() => unawaited(_changes.close());
}

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
