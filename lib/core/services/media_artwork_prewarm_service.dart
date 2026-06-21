import 'dart:async';
import 'dart:developer' as developer;

import '../models/playback_state.dart';
import '../models/track.dart';
import 'media_artwork_source.dart';

/// Secret-free diagnostic tag for the media-session artwork warm path. View with
/// `adb logcat | grep Linthra.MediaArtwork`. Logs only structural outcomes
/// (a warm produced a local cover, or didn't) — never a URL, credential, or id.
const String _logName = 'Linthra.MediaArtwork';

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
/// the handler can attach the already-cached `content://` cover synchronously
/// when the track becomes current, beating the snapshot. Platform-loadable
/// covers (Jellyfin http, a local `file:`) need no warming and are skipped.
///
/// Best-effort by design, mirroring the stream preloader: warms run
/// sequentially, one at a time, off the playback path; the now-playing cover is
/// warmed first; a reference that succeeds is warmed once, while a transient
/// failure is allowed to retry on a later queue change; and the cache swallows
/// every failure (returning null), so a slow or failing fetch can never stall or
/// restart playback.
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
    // Prioritise the now-playing cover (front of the queue) so it warms before
    // the look-ahead — its delay is the one visible on the now-playing card.
    _enqueue(state.currentTrack?.artworkUri, front: true);
    for (final Track track in state.upNext.take(_lookahead)) {
      _enqueue(track.artworkUri, front: false);
    }
    unawaited(_drain());
  }

  /// Queues [art] to be warmed if it's a fetchable reference not already
  /// warmed/warming. The now-playing cover goes to the [front] so it fetches
  /// ahead of the look-ahead covers; Jellyfin (`http`) / local (`file`) covers
  /// load directly and are skipped.
  void _enqueue(Uri? art, {required bool front}) {
    if (art == null) return;
    if (isPlatformLoadableArtwork(art)) return;
    if (!_requested.add(art)) return;
    if (front) {
      _queue.insert(0, art);
    } else {
      _queue.add(art);
    }
  }

  /// A fingerprint of the now-playing + look-ahead track uris, so warming reacts
  /// to queue/track changes but not to position/status ticks (same key). Keyed by
  /// uri (not the bare id) so switching between two providers' same-id copies
  /// still triggers a warm.
  String _keyFor(PlaybackState state) {
    final String current = state.currentTrack?.uri ?? '-';
    final String ahead =
        state.upNext.take(_lookahead).map((Track t) => t.uri).join(',');
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
          final Uri? local = await _warm(reference);
          if (local == null) {
            // A transient miss (signed out / fetch failed): drop it from the
            // warmed set so a later queue change can retry, rather than leaving
            // that track coverless for the whole session.
            _requested.remove(reference);
          }
          // Secret-free trace: did this cover cache to a safe local URI? `ok`
          // means a later now-playing item can carry it; `miss` means signed
          // out / fetch failed. No URL, credential, or id is logged.
          developer.log('warm: ${local == null ? 'miss' : 'ok'}',
              name: _logName);
        } catch (_) {
          // Swallow + allow a later retry: a failed/throwing warm just means no
          // cover for that track right now.
          _requested.remove(reference);
          developer.log('warm: error', name: _logName);
        }
      }
    } finally {
      _running = false;
    }
  }

  Future<void> dispose() => _subscription.cancel();
}
