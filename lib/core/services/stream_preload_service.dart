import 'dart:async';

import '../models/playback_state.dart';
import '../models/repeat_mode.dart';
import '../models/track.dart';
import 'stream_preloader.dart';

/// Warms the **immediate next** remote track's stream URL as playback moves, so
/// a skip — or the natural roll into the next track — starts faster instead of
/// re-running the session check + URL probe at the track change.
///
/// It listens to the unified [PlaybackState] and, whenever what-plays-next
/// changes, asks a [StreamPreloader] to warm `upNext.first`. Because the
/// controller keeps `upNext` in effective play order, this preloads the
/// queue-order next track normally and the shuffled-order next track when
/// shuffle is on, with no special-casing.
///
/// What it deliberately does NOT do:
///  - **Repeat-one stays calm.** The current track loops, so the up-next won't
///    play soon — nothing is preloaded.
///  - **No disk, no downloads.** Preloading only warms an in-memory URL via the
///    [StreamPreloader]; it never writes the offline cache or marks a track as
///    downloaded. A local/non-remote next track is a no-op in the preloader.
///  - **Best-effort, never blocking.** Warms run off the playback path, one at a
///    time, and a failure is swallowed — so a slow or failing warm never stalls
///    or restarts the current track.
class StreamPreloadService {
  StreamPreloadService({
    required Stream<PlaybackState> playbackStates,
    required StreamPreloader preloader,
  }) : _preloader = preloader {
    _subscription = playbackStates.listen(_onState);
  }

  final StreamPreloader _preloader;
  late final StreamSubscription<PlaybackState> _subscription;

  /// The last set of inputs we preloaded against, so pure position/status ticks
  /// don't re-trigger a warm.
  String? _lastKey;
  Track? _pending;
  bool _running = false;

  void _onState(PlaybackState state) {
    final String key = _keyFor(state);
    // Only react when something that affects *what plays next* changed — not on
    // every position tick (which re-emits the same key).
    if (key == _lastKey) return;
    _lastKey = key;
    if (state.currentTrack == null) return;
    // Repeat-one replays the current track, so the up-next won't play soon:
    // don't preload unrelated tracks.
    if (state.repeatMode == RepeatMode.one) return;
    if (state.upNext.isEmpty) return;
    // Warm the immediate next track only — the highest-value, lowest-cost win.
    // (Further-ahead warming to *disk* is the smart pre-cache's job.)
    _pending = state.upNext.first;
    unawaited(_drain());
  }

  /// A fingerprint of the inputs that decide the next track: the playing track,
  /// shuffle, repeat, and the head of up-next. Excludes position/duration/status
  /// so listening doesn't thrash on playback ticks.
  static String _keyFor(PlaybackState state) {
    final String current = state.currentTrack?.id ?? '-';
    final String next = state.upNext.isEmpty ? '-' : state.upNext.first.id;
    return '$current|${state.shuffleEnabled}|${state.repeatMode.name}|$next';
  }

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (_pending != null) {
        final Track track = _pending!;
        _pending = null;
        // Sequential on purpose: one warm at a time keeps it off the playback
        // path and lets a newer queue (set while a warm is in flight) win.
        await _preloader.preload(track);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> dispose() => _subscription.cancel();
}
