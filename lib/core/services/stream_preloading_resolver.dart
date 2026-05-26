import '../models/playback_source.dart';
import '../models/track.dart';
import 'playable_uri_resolver.dart';
import 'stream_preloader.dart';

/// A [PlayableUriResolver] decorator that pre-resolves upcoming remote stream
/// URLs and serves them on the next play, so a track change doesn't pay the
/// session-check + probe latency again.
///
/// How it behaves:
///  - [preload] resolves a remote track through the wrapped resolver and stores
///    the result in an in-memory map keyed by track id, with a short TTL.
///  - [resolve] returns a *fresh, unexpired* preloaded entry **once**
///    (consume-on-read) and otherwise delegates to the wrapped resolver. So a
///    retry after a failed load re-resolves a fresh URL rather than replaying a
///    possibly-stale one, and a repeat/replay later also re-resolves fresh.
///
/// What it deliberately does **not** do: it never touches the offline cache,
/// never marks a track as downloaded, persists nothing, and logs nothing. It
/// only ever holds short-lived remote stream URLs in memory, and swallows any
/// resolution error during a warm — so a token-bearing URL can't leak through a
/// preload path, and a failed warm just means the track resolves normally when
/// it is actually reached.
class StreamPreloadingResolver implements PlayableUriResolver, StreamPreloader {
  StreamPreloadingResolver(
    this._inner, {
    Duration ttl = const Duration(minutes: 2),
    DateTime Function()? clock,
  })  : _ttl = ttl,
        _now = clock ?? DateTime.now;

  final PlayableUriResolver _inner;
  final Duration _ttl;
  final DateTime Function() _now;

  final Map<String, _PreloadedResolution> _cache =
      <String, _PreloadedResolution>{};

  /// Remote stream schemes worth preloading; local files and `content://`
  /// documents open instantly and need no warming.
  static const Set<String> _remoteSchemes = <String>{'jellyfin', 'subsonic'};

  @override
  bool handles(Track track) => _inner.handles(track);

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    // Consume-on-read: a warmed URL is a one-shot. Removing it means a later
    // retry/replay of the same track re-resolves fresh instead of reusing a
    // possibly-expired URL.
    final _PreloadedResolution? cached = _cache.remove(track.id);
    if (cached != null && cached.expiresAt.isAfter(_now())) {
      return cached.resolved;
    }
    return _inner.resolve(track);
  }

  @override
  Future<void> preload(Track track) async {
    if (!_isRemoteStream(track) || !_inner.handles(track)) return;
    // Already warm and unexpired: don't re-resolve (and don't spend a request).
    final _PreloadedResolution? existing = _cache[track.id];
    if (existing != null && existing.expiresAt.isAfter(_now())) return;
    try {
      final ResolvedPlayable resolved = await _inner.resolve(track);
      // Only hold short-lived remote stream URLs in memory; never cache a local
      // path or a cache-hit (those carry no benefit and shouldn't be retained).
      if (resolved.source == PlaybackSource.streamingDirect) {
        _cache[track.id] = _PreloadedResolution(resolved, _now().add(_ttl));
      }
    } catch (_) {
      // Best-effort: a failed warm just means the track resolves normally when
      // it is reached. Never rethrow, never log (no URL/token must leak).
    }
  }

  static bool _isRemoteStream(Track track) {
    final String scheme = Uri.tryParse(track.uri)?.scheme.toLowerCase() ?? '';
    return _remoteSchemes.contains(scheme);
  }
}

class _PreloadedResolution {
  const _PreloadedResolution(this.resolved, this.expiresAt);

  final ResolvedPlayable resolved;
  final DateTime expiresAt;
}
