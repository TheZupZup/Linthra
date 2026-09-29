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
  /// per provider when a queue is first seen; a track is only fetched, and its
  /// bytes only kept, while its provider is still on that same account.
  final String? Function(Track track)? _sessionScopeOf;

  late final StreamSubscription<PlaybackState> _subscription;
  StreamSubscription<NetworkStatus>? _networkSubscription;

  /// The last state accepted, and the work it stands for, so position and
  /// status ticks (which don't change what to cache) don't re-trigger a pass.
  PlaybackState? _lastInputs;
  _PrecacheJob? _lastJob;
  _PrecacheJob? _pending;
  bool _running = false;
  bool _disposed = false;

  /// Bumped whenever the queue to warm changes. A pass remembers the value it
  /// started with and stops as soon as it moves on.
  int _generation = 0;

  NetworkStatus? _lastNetwork;

  void _onState(PlaybackState state) {
    if (_disposed) return;
    final PlaybackState? last = _lastInputs;
    final bool sameSurroundings = last != null &&
        state.currentTrack?.uri == last.currentTrack?.uri &&
        state.shuffleEnabled == last.shuffleEnabled &&
        state.repeatMode == last.repeatMode;
    // A position or status tick hands over the very same queue lists, so
    // nothing that decides what to cache can have moved. A handful of
    // reference checks, no allocation.
    if (last != null &&
        sameSurroundings &&
        identical(state.upNext, last.upNext) &&
        identical(state.previous, last.previous)) {
      return;
    }
    // Otherwise compare what would actually be warmed. That is the
    // de-duplicated window, not the raw head of the queue: `[A, A, …, B]`
    // becoming `[A, A, …, C]` changes it even when the first entries match.
    final List<Track> upcoming =
        upcomingTracks(state, count: kMaxPrecacheCount);
    final _PrecacheJob? lastJob = _lastJob;
    _lastInputs = state;
    if (sameSurroundings &&
        lastJob != null &&
        _sameTracks(upcoming, lastJob.upcoming)) {
      return;
    }
    if (state.currentTrack == null) {
      // Nothing is playing any more: whatever pass is running is obsolete.
      _generation++;
      _pending = null;
      _lastJob = null;
      return;
    }
    final _PrecacheJob job = (
      state: state,
      upcoming: upcoming,
      scopes: _scopesFor(upcoming),
    );
    _lastJob = job;
    _schedule(job);
  }

  void _onNetwork(NetworkStatus status) {
    final NetworkStatus? previous = _lastNetwork;
    _lastNetwork = status;
    if (_disposed || status == previous) return;
    // Offline can't fetch anything; the pass would only skip. Everything else
    // (back online, or moved to an unmetered network) may let it run now.
    if (status == NetworkStatus.offline) return;
    final _PrecacheJob? last = _lastJob;
    if (last == null) return;
    StabilityDiagnostics.precache('resume:network');
    // Still bound to the accounts that were signed in when this queue was
    // seen, not whatever is signed in now.
    _schedule(last);
  }

  /// Makes [job] the queue to warm next, superseding any pass in progress.
  void _schedule(_PrecacheJob job) {
    _generation++;
    // Remember the freshest work and drain; a pass already running stops at
    // its next item and the drain picks this up, so the latest queue wins.
    _pending = job;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (_pending != null && !_disposed) {
        final _PrecacheJob job = _pending!;
        _pending = null;
        await _precacheUpcoming(job, _generation);
      }
    } finally {
      _running = false;
    }
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  Future<void> _precacheUpcoming(_PrecacheJob job, int generation) async {
    final PlaybackState state = job.state;
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
    // The first [aheadCount] of the window worked out when the queue was seen:
    // [upcomingTracks] keeps order, so this is exactly the shorter window.
    final List<Track> upcoming = job.upcoming.take(aheadCount).toList();
    if (upcoming.isEmpty || !_isCurrent(generation)) return;
    // What a warm must not evict to make room: the playing track and the
    // tracks that play before the one being warmed. Farther ones stay fair
    // game, so under a tight limit the queue order decides what is kept: the
    // next track can push out a stale copy of one further on, never the other
    // way round.
    final List<Track> keep = <Track>[state.currentTrack!];
    // Secret-free count only, never which tracks. A real pre-cache pass per
    // queue change (not per position tick, see [_onState]) reads as one log.
    StabilityDiagnostics.precache('start:${upcoming.length}');
    for (final Track track in upcoming) {
      keep.add(track);
      // The queue moved on while the previous track was fetching: this list is
      // obsolete, so stop and let the drain start the current queue's pass.
      if (!_isCurrent(generation)) {
        StabilityDiagnostics.precache('superseded');
        return;
      }
      // The account this queue was built under. If the provider has since
      // signed out or switched, this track belongs to a catalog the current
      // session doesn't have: fetching it would store the wrong bytes.
      final String? scope = job.scopes[_providerOf(track)];
      if (_scopeOf(track) != scope) {
        StabilityDiagnostics.precache('skip:session-changed');
        continue;
      }
      // Sequential on purpose: one warm fetch at a time keeps pre-cache off the
      // critical path and lets the cache limit settle between writes.
      await _prefetcher.prefetch(
        track,
        keep: List<Track>.of(keep),
        isStillWanted: () => !_disposed && _scopeOf(track) == scope,
      );
    }
  }

  /// The account each provider in [tracks] is signed in with right now, keyed
  /// by provider. Worked out once per queue, when it is first seen.
  Map<String, String?> _scopesFor(List<Track> tracks) {
    if (_sessionScopeOf == null) return const <String, String?>{};
    final Map<String, String?> scopes = <String, String?>{};
    for (final Track track in tracks) {
      scopes.putIfAbsent(_providerOf(track), () => _scopeOf(track));
    }
    return scopes;
  }

  /// The provider part of a track's opaque uri (`jellyfin`, `plex`, …), or an
  /// empty string for a local path.
  static String _providerOf(Track track) {
    final int colon = track.uri.indexOf(':');
    return colon <= 0 ? '' : track.uri.substring(0, colon);
  }

  static bool _sameTracks(List<Track> a, List<Track> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].uri != b[i].uri) return false;
    }
    return true;
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
    _pending = null;
    // No event reaches [_onNetwork] once cancel is called. Cancelling a
    // platform event stream waits on the native side to acknowledge, which
    // must never hold up shutdown, so that wait isn't awaited.
    unawaited(
      _networkSubscription?.cancel().catchError((Object _) {}),
    );
    await _subscription.cancel();
  }
}

/// One queue's worth of pre-cache work: the state it came from, the tracks it
/// would warm (up to the largest count a user can pick), and the account each
/// provider was signed in with when the queue was seen.
typedef _PrecacheJob = ({
  PlaybackState state,
  List<Track> upcoming,
  Map<String, String?> scopes,
});
