import 'dart:async';

import '../models/playback_state.dart';
import '../models/repeat_mode.dart';
import '../models/track.dart';
import '../repositories/download_preferences.dart';
import 'stability_diagnostics.dart';
import 'track_prefetcher.dart';

/// Smart pre-cache: warms a small number of upcoming Jellyfin tracks into the
/// offline cache as playback moves, so the next songs start instantly (and play
/// offline) instead of buffering a fresh stream at each track change — the
/// Plex/Plexamp-style "the next track is already here" feel, kept deliberately
/// modest so it never fills the phone or downloads the whole library.
///
/// It listens to the unified [PlaybackState] stream and, whenever the inputs
/// that decide *what to cache* change — the playing track, the queue's up-next,
/// shuffle, or repeat mode — asks a [TrackPrefetcher] to warm the next
/// `precacheCount` entries of the up-next list. Because the controller keeps
/// `upNext` in effective play order, this pre-caches the **queue order** in
/// normal playback and the **shuffled order** when shuffle is on, with no
/// special-casing. The stream is the *active* output's, so while casting it
/// still pre-caches the active queue (the queue is always owned locally).
///
/// What it does NOT do is just as important:
///  - **Repeat-one stays calm.** When the current track loops, the up-next
///    won't play soon, so pre-caching it would be wasted data and storage — the
///    service caches nothing extra and lets those tracks stream if reached.
///  - **It only decides what/when.** Everything that *bounds* a pre-cache lives
///    downstream in the [TrackPrefetcher]: it pre-caches only remote tracks
///    (skipping local files, already on disk), avoids duplicates, honours the
///    mobile-data policy (Wi-Fi always; mobile data only when the user allowed
///    it; never offline), stays under the cache limit (evicting pre-cached entries
///    before any user download), and never throws. A pre-cache never blocks or
///    interrupts what's playing.
///  - **One at a time.** Pre-caches run sequentially (effective concurrency 1),
///    off the playback path, so the cache limit settles between writes and the
///    app never opens an unbounded number of requests.
///
/// Smart pre-cache is automatic and *evictable*. To keep a song permanently,
/// the user pins it with "Keep offline" on the Downloads screen — those manual
/// downloads are protected and never auto-evicted (see `CacheEvictionPolicy`).
class SmartPrecacheService {
  SmartPrecacheService({
    required Stream<PlaybackState> playbackStates,
    required TrackPrefetcher prefetcher,
    required DownloadPreferences preferences,
  })  : _prefetcher = prefetcher,
        _preferences = preferences {
    _subscription = playbackStates.listen(_onState);
  }

  final TrackPrefetcher _prefetcher;
  final DownloadPreferences _preferences;
  late final StreamSubscription<PlaybackState> _subscription;

  /// The last set of inputs we pre-cached against, so pure position/status
  /// ticks (which don't change what to cache) don't re-trigger a pass.
  String? _lastKey;
  PlaybackState? _pendingState;
  bool _running = false;

  void _onState(PlaybackState state) {
    final String key = _keyFor(state);
    // React only when something that affects *what to cache* changed — the
    // playing track, the up-next list, shuffle, or repeat — not on every
    // position tick (which re-emits the same key).
    if (key == _lastKey) return;
    _lastKey = key;
    if (state.currentTrack == null) return;
    // Remember the freshest state and drain; a pass already running picks this
    // up when it finishes, so the latest queue always wins.
    _pendingState = state;
    unawaited(_drain());
  }

  /// A cheap fingerprint of the inputs that decide what to pre-cache. Excludes
  /// position/duration/status so listening doesn't thrash on playback ticks.
  static String _keyFor(PlaybackState state) {
    final StringBuffer buffer = StringBuffer()
      ..write(state.currentTrack?.uri ?? '-')
      ..write('|')
      ..write(state.shuffleEnabled)
      ..write('|')
      ..write(state.repeatMode.name)
      ..write('|');
    for (final Track track in state.upNext) {
      buffer
        ..write(track.uri)
        ..write(',');
    }
    return buffer.toString();
  }

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (_pendingState != null) {
        final PlaybackState state = _pendingState!;
        _pendingState = null;
        await _precacheUpcoming(state);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _precacheUpcoming(PlaybackState state) async {
    final List<Track> upNext = state.upNext;
    if (upNext.isEmpty) return;
    if (!await _preferences.preloadEnabled()) {
      StabilityDiagnostics.precache('skip:disabled');
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
    if (aheadCount <= 0) return;
    final int count = upNext.length < aheadCount ? upNext.length : aheadCount;
    // Secret-free count only — never which tracks. A real pre-cache pass per
    // queue change (not per position tick — see [_onState]) reads as one log.
    StabilityDiagnostics.precache('start:$count');
    for (int i = 0; i < count; i++) {
      // Sequential on purpose: one warm fetch at a time keeps pre-cache off the
      // critical path and lets the cache limit settle between writes.
      await _prefetcher.prefetch(upNext[i]);
    }
  }

  Future<void> dispose() => _subscription.cancel();
}
