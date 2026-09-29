import 'dart:async';

import '../models/playback_state.dart';
import '../models/repeat_mode.dart';
import '../models/track.dart';
import '../repositories/download_preferences.dart';
import 'connectivity_service.dart';
import 'playback_lookahead.dart';
import 'stability_diagnostics.dart';
import 'track_prefetcher.dart';

/// Smart pre-cache: warms a small number of upcoming remote tracks into the
/// offline cache as playback moves, so the next songs start instantly (and play
/// offline) instead of buffering a fresh stream at each track change — the
/// Plex/Plexamp-style "the next track is already here" feel, kept deliberately
/// modest so it never fills the phone or downloads the whole library.
///
/// It listens to the unified [PlaybackState] stream and, whenever the inputs
/// that decide *what to cache* change (the playing track, the queue's up-next,
/// shuffle, or repeat mode), asks a [TrackPrefetcher] to warm the tracks
/// [upcomingTracks] says the controller will play next, up to the user's
/// `precacheCount`. That follows the controller's own effective order: queue
/// order normally, the already-shuffled order when shuffle is on, and the wrap
/// back to the start under repeat-all. The stream is the *active* output's, so
/// while casting it still pre-caches the active queue (the queue is always owned
/// locally).
///
/// The queue it works from is always the latest one:
///  - **An obsolete queue stops.** When the queue changes mid-pass (a skip, Play
///    Next, a new album, shuffle), the pass stops after the fetch already in
///    flight and the new queue's pass starts. That fetch is allowed to finish
///    rather than being thrown away and fetched again.
///  - **Network recovery resumes it.** When a [networkChanges] stream is wired
///    and the connection comes back (or moves to an unmetered one), the current
///    queue is warmed again; there is no polling.
///  - **Stale sessions can't write.** Each fetch carries a check the prefetcher
///    asks again before committing: if the provider account that asked for the
///    track signed out or switched ([sessionScopeOf] changed), or this service
///    was disposed, the bytes are dropped.
///
/// What it does NOT do is just as important:
///  - **Repeat-one stays calm.** When the current track loops, the up-next
///    won't play soon, so pre-caching it would be wasted data and storage — the
///    service caches nothing extra and lets those tracks stream if reached.
///  - **It only decides what/when.** Everything that *bounds* a pre-cache lives
///    downstream in the [TrackPrefetcher]: it pre-caches only remote tracks
///    (skipping local files, already on disk), avoids duplicates, honours the
///    mobile-data profile and active-network policy, stays under the cache limit
///    (evicting only older pre-cached entries, never a user download and never
///    the tracks this pass is keeping), and never throws. A pre-cache never
///    blocks or interrupts what's playing.
///  - **One at a time.** Pre-caches run sequentially (effective concurrency 1),
///    off the playback path, so the cache limit settles between writes and the
///    app never opens an unbounded number of requests.
///
/// Smart pre-cache is automatic and *evictable*. To keep a song permanently,
/// the user downloads it (and can pin it with "Keep offline"); automatic
/// caching never removes those (see `CacheEvictionPolicy`).
class SmartPrecacheService {
  SmartPrecacheService({
    required Stream<PlaybackState> playbackStates,
    required TrackPrefetcher prefetcher,
    required DownloadPreferences preferences,
    Stream<NetworkStatus>? networkChanges,
    String? Function(Track track)? sessionScopeOf,
  })  : _prefetcher = prefetcher,
        _preferences = preferences,
        _sessionScopeOf = sessionScopeOf {
    _subscription = playbackStates.listen(_onState);
    _networkSubscription = networkChanges?.listen(
      _onNetwork,
      // A connectivity stream that fails just means no early resume; the next
      // queue change still warms the queue.
      onError: (Object _, StackTrace __) {},
    );
  }

  final TrackPrefetcher _prefetcher;
  final DownloadPreferences _preferences;

  /// The non-secret identity of the signed-in account a track would be fetched
  /// with (`jellyfin:<fingerprint>`, …), or `null` when signed out. Captured
  /// when a fetch starts and compared again before its bytes are committed.
  final String? Function(Track track)? _sessionScopeOf;

  late final StreamSubscription<PlaybackState> _subscription;
  StreamSubscription<NetworkStatus>? _networkSubscription;

  /// The last set of inputs we pre-cached against, so pure position/status
  /// ticks (which don't change what to cache) don't re-trigger a pass.
  PlaybackState? _lastInputs;
  PlaybackState? _pendingState;
  bool _running = false;
  bool _disposed = false;

  /// Bumped whenever the queue to warm changes. A pass remembers the value it
  /// started with and stops as soon as it moves on.
  int _generation = 0;

  NetworkStatus? _lastNetwork;

  void _onState(PlaybackState state) {
    if (_disposed) return;
    // React only when something that affects *what to cache* changed — the
    // playing track, the head of up-next, shuffle, or repeat — not on every
    // position tick, which changes none of them. The comparison itself is
    // allocation-free and short-circuits on an unchanged queue, so a tick costs
    // a handful of reference checks (see [samePlaybackLookahead]).
    if (samePlaybackLookahead(
      state,
      _lastInputs,
      ahead: kMaxPrecacheCount,
      wrapsIntoHistory: true,
    )) {
      return;
    }
    _lastInputs = state;
    if (state.currentTrack == null) {
      // Nothing is playing any more: whatever pass is running is obsolete.
      _generation++;
      _pendingState = null;
      return;
    }
    _schedule(state);
  }

  void _onNetwork(NetworkStatus status) {
    final NetworkStatus? previous = _lastNetwork;
    _lastNetwork = status;
    if (_disposed || status == previous) return;
    // Offline can't fetch anything; the pass would only skip. Everything else
    // (back online, or moved to an unmetered network) may let it run now.
    if (status == NetworkStatus.offline) return;
    final PlaybackState? last = _lastInputs;
    if (last == null || last.currentTrack == null) return;
    StabilityDiagnostics.precache('resume:network');
    _schedule(last);
  }

  /// Makes [state] the queue to warm next, superseding any pass in progress.
  void _schedule(PlaybackState state) {
    _generation++;
    // Remember the freshest state and drain; a pass already running stops at
    // its next item and the drain picks this up, so the latest queue wins.
    _pendingState = state;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (_pendingState != null && !_disposed) {
        final PlaybackState state = _pendingState!;
        _pendingState = null;
        await _precacheUpcoming(state, _generation);
      }
    } finally {
      _running = false;
    }
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  Future<void> _precacheUpcoming(PlaybackState state, int generation) async {
    if (state.upNext.isEmpty && state.previous.isEmpty) return;
    if (!await _preferences.preloadEnabled()) {
      StabilityDiagnostics.precache('skip:disabled');
      return;
    }
    final MobileDataProfile profile = await _preferences.mobileDataProfile();
    if (profile.pausesSmartPrecache) {
      StabilityDiagnostics.precache('skip:save-data-profile');
      return;
    }
    // Repeat-one replays the current track indefinitely, so the up-next won't
    // play soon. Don't aggressively pre-cache unrelated tracks — stay quiet.
    if (state.repeatMode == RepeatMode.one) {
      StabilityDiagnostics.precache('skip:repeat-one');
      return;
    }
    final int aheadCount = sanitizePrecacheCount(
      await _preferences.precacheCount(),
    );
    final List<Track> upcoming = upcomingTracks(state, count: aheadCount);
    if (upcoming.isEmpty || !_isCurrent(generation)) return;
    // What this pass must not evict while it makes room: the playing track and
    // everything it is about to warm.
    final List<Track> keep = <Track>[state.currentTrack!, ...upcoming];
    // Secret-free count only — never which tracks. A real pre-cache pass per
    // queue change (not per position tick — see [_onState]) reads as one log.
    StabilityDiagnostics.precache('start:${upcoming.length}');
    for (final Track track in upcoming) {
      // The queue moved on while the previous track was fetching: this list is
      // obsolete, so stop and let the drain start the current queue's pass.
      if (!_isCurrent(generation)) {
        StabilityDiagnostics.precache('superseded');
        return;
      }
      final String? scope = _scopeOf(track);
      // Sequential on purpose: one warm fetch at a time keeps pre-cache off the
      // critical path and lets the cache limit settle between writes.
      await _prefetcher.prefetch(
        track,
        keep: keep,
        isStillWanted: () => !_disposed && _scopeOf(track) == scope,
      );
    }
  }

  String? _scopeOf(Track track) {
    final String? Function(Track track)? scopeOf = _sessionScopeOf;
    if (scopeOf == null) return null;
    try {
      return scopeOf(track);
    } catch (_) {
      // An unreadable session is treated like a signed-out one.
      return null;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _generation++;
    _pendingState = null;
    // No event reaches [_onNetwork] once cancel is called. Cancelling a
    // platform event stream waits on the native side to acknowledge, which
    // must never hold up shutdown, so that wait isn't awaited.
    unawaited(
      _networkSubscription?.cancel().catchError((Object _) {}),
    );
    await _subscription.cancel();
  }
}
