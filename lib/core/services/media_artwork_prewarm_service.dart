import 'dart:async';

import '../models/playback_state.dart';
import '../models/track.dart';
import 'media_artwork_source.dart';

/// Warms the now-playing track's and the next few up-next tracks' media-session
/// cover art into the local cache, off the playback path, so each cover is
/// cached *before* its track reaches the now-playing card.
///
/// Why ahead of time: the platform media session loads `MediaItem.artUri`
/// itself, and many car head units snapshot the now-playing art at the track
/// change and don't refresh it. A credential-free cover *reference* (e.g.
/// Subsonic's `subsonic-cover:<id>`) must be fetched to a local file first, which
/// is too slow to do at the moment the track flips — so a cover fetched only
/// then arrives after the snapshot and never shows. Warming the look-ahead means
/// the handler can attach the already-cached `file:` synchronously when the track
/// becomes current, beating the snapshot. Platform-loadable covers (Jellyfin
/// http, a local `file:`) need no warming and are skipped.
///
/// Best-effort by design, mirroring the stream preloader: warms run
/// sequentially, one at a time, off the playback path; each reference is warmed
/// at most once per session; and the cache swallows every failure (returning
/// null), so a slow or failing fetch can never stall or restart playback.
class MediaArtworkPrewarmService {
  MediaArtworkPrewarmService({
    required Stream<PlaybackState> playbackStates,
    required Future<Uri?> Function(Uri reference) warm,
    int lookahead = _defaultLookahead,
  })  : _warm = warm,
        _lookahead = lookahead {
    _subscription = playbackStates.listen(_onState);
  }

  /// Fetches+caches the cover for a credential-free [reference], returning the
  /// local URI or null; the result is ignored here (the cache memoizes it for
  /// the handler's synchronous `cached` lookup). Never throws.
  final Future<Uri?> Function(Uri reference) _warm;

  /// How many up-next tracks (beyond the current one) to warm ahead.
  final int _lookahead;

  late final StreamSubscription<PlaybackState> _subscription;

  static const int _defaultLookahead = 3;

  /// References already warmed (or warming) this session, so a re-emitted state
  /// (a position tick, a pause) never re-warms a cover.
  final Set<Uri> _requested = <Uri>{};
  final List<Uri> _queue = <Uri>[];
  bool _running = false;
  String? _lastKey;

  void _onState(PlaybackState state) {
    final String key = _keyFor(state);
    // Only react when the now-playing + look-ahead set changes — not on every
    // position tick (which re-emits the same key).
    if (key == _lastKey) return;
    _lastKey = key;
    for (final Track track in _tracksToWarm(state)) {
      final Uri? art = track.artworkUri;
      if (art == null) continue;
      // Jellyfin http / local file covers load directly: nothing to fetch.
      if (isPlatformLoadableArtwork(art)) continue;
      // Each reference is warmed at most once per session.
      if (!_requested.add(art)) continue;
      _queue.add(art);
    }
    unawaited(_drain());
  }

  /// The now-playing track followed by the look-ahead of up-next tracks — the
  /// covers worth having cached before they reach the now-playing card.
  Iterable<Track> _tracksToWarm(PlaybackState state) sync* {
    final Track? current = state.currentTrack;
    if (current != null) yield current;
    yield* state.upNext.take(_lookahead);
  }

  /// A fingerprint of the now-playing + look-ahead track ids, so warming reacts
  /// to queue/track changes but not to position/status ticks (same key).
  String _keyFor(PlaybackState state) {
    final String current = state.currentTrack?.id ?? '-';
    final String ahead =
        state.upNext.take(_lookahead).map((Track t) => t.id).join(',');
    return '$current|$ahead';
  }

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (_queue.isNotEmpty) {
        final Uri reference = _queue.removeAt(0);
        // Sequential + best-effort: the cache fetches a server-downscaled cover,
        // caches it, and returns null on any failure. The try/catch is purely
        // defensive — a warm must never surface as an uncaught async error or
        // break the drain (and so can never touch playback).
        try {
          await _warm(reference);
        } catch (_) {
          // Swallow: a failed/throwing warm just means no cover for that track.
        }
      }
    } finally {
      _running = false;
    }
  }

  Future<void> dispose() => _subscription.cancel();
}
