import '../../models/track.dart';
import '../playable_uri_resolver.dart';
import '../stream_preloader.dart';
import 'remote_cache_entry.dart';
import 'remote_cache_index.dart';
import 'remote_cache_key.dart';
import 'remote_cache_policy.dart';
import 'remote_playback_cache.dart';

/// The **write side** of the remote playback cache: it pre-resolves upcoming
/// remote stream URLs and stores them in a shared [RemotePlaybackCache] so the
/// paired [RemoteCacheResolver] can serve them instantly at the next play.
///
/// "Aggressive but safe" prebuffering:
///  - [prepare] warms the **current** remote track (so a resume/retry is ready)
///    and the **next** queue item(s) before a transition — more eager than
///    warming only the immediate next, which is what reduces the cut when a user
///    skips quickly or a track rolls over on a flaky connection.
///  - [preload] (the [StreamPreloader] seam) warms a single track, so existing
///    next-track drivers keep working unchanged.
///
/// Non-negotiable safety, mirroring the previous preloader:
///  - **Best-effort, never fatal.** Every warm is wrapped; a failure is
///    swallowed and never rethrown, so prebuffering can never fail or stall the
///    current track.
///  - **No secrets on disk.** It only ever holds a short-lived remote URL *in
///    memory* via the cache; it never writes the offline cache, never marks a
///    track downloaded, and never logs the resolved URL (so a token can't leak
///    through this path). When an optional [RemoteCacheIndex] is wired it
///    persists only the warmed track's *credential-free* key (never the URL),
///    so the durable manifest cannot carry a secret either.
///  - **Remote-only.** Local files and `content://` documents have no cache key
///    (see [RemoteCacheKey]) and are skipped outright.
///  - **Freshness-aware & idempotent.** It sweeps stale entries and skips a
///    track that is already warm, so rapid duplicate requests spend one resolve.
class RemoteStreamPrebufferer implements StreamPreloader {
  RemoteStreamPrebufferer({
    required PlayableUriResolver resolver,
    required RemotePlaybackCache cache,
    RemoteCachePolicy policy = const RemoteCachePolicy(),
    RemoteCacheIndex? index,
    DateTime Function()? clock,
  })  : _resolver = resolver,
        _cache = cache,
        _policy = policy,
        _index = index,
        _now = clock ?? DateTime.now;

  final PlayableUriResolver _resolver;
  final RemotePlaybackCache _cache;
  final RemoteCachePolicy _policy;

  /// The optional durable, credential-free index. When wired, a successful warm
  /// records the track's key (never its URL) so the cache's knowledge survives a
  /// restart. Best-effort: [RemoteCacheIndex.record] never throws.
  final RemoteCacheIndex? _index;

  final DateTime Function() _now;

  @override
  Future<void> preload(Track track) => _prebuffer(track);

  /// Aggressively prepares playback: warms [current] and the first [ahead]
  /// entries of [upNext] into the cache, dropping any stale entries first.
  /// Best-effort and sequential (one warm at a time keeps it off the playback
  /// path and lets a newer queue win); never throws.
  Future<void> prepare({
    Track? current,
    List<Track> upNext = const <Track>[],
    int ahead = 1,
  }) async {
    _cache.sweep(_now());
    if (current != null) await _prebuffer(current);
    final int count = ahead < upNext.length ? ahead : upNext.length;
    for (int i = 0; i < count; i++) {
      await _prebuffer(upNext[i]);
    }
  }

  Future<void> _prebuffer(Track track) async {
    final RemoteCacheKey? key = RemoteCacheKey.forTrack(track);
    // Not a remote stream (local / content:// / tokenized): nothing to warm.
    if (key == null) return;
    if (!_resolver.handles(track)) return;
    // Already warm and fresh: don't re-resolve (and don't spend a request).
    if (_cache.contains(key, _now())) return;
    try {
      final ResolvedPlayable resolved = await _resolver.resolve(track);
      // Only retain a fresh direct-stream URL; a local path or offline-cache hit
      // carries no benefit and must not be held here.
      if (_policy.isStorable(resolved.source)) {
        final RemoteCacheEntry entry =
            _policy.buildEntry(key: key, resolved: resolved, now: _now());
        _cache.store(entry);
        // Remember the warm in the durable, credential-free index so the cache's
        // knowledge survives a restart. Best-effort and never throws; only the
        // opaque key is persisted, never the token-bearing stream URL.
        await _index?.record(entry);
      }
    } catch (_) {
      // Best-effort: a failed warm just means the track resolves normally when
      // it is reached. Never rethrow, never log (no URL/token must leak).
    }
  }
}
