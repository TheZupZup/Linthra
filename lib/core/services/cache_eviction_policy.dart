import '../repositories/download_store.dart';

/// What to evict (and whether the incoming download fits at all) for one
/// download request — the output of [CacheEvictionPolicy].
class EvictionPlan {
  const EvictionPlan({required this.evict, required this.fits});

  /// The tracks to delete to make room, least-recently-used first. Empty when
  /// nothing needs to go (or when [fits] is `false`, since freeing space that
  /// still wouldn't be enough only loses the user's downloads for nothing).
  final List<CachedTrack> evict;

  /// Whether the incoming bytes fit once [evict] is removed. `false` means
  /// "Not enough cache space" — the caller should refuse and keep what's there.
  final bool fits;

  static const EvictionPlan empty =
      EvictionPlan(evict: <CachedTrack>[], fits: true);
}

/// Decides, purely, what to evict so a new download stays under the cache
/// limit. No I/O and no app state — it takes the current cache metadata and
/// returns a plan — which keeps the rules exhaustively testable and the
/// repository free of branching policy logic.
///
/// Rules, in order:
///  - On-device tracks and zero-byte records don't count toward the budget and
///    are never evicted (they hold no app-managed bytes).
///  - The currently playing track is never evicted.
///  - Pinned ("Keep offline") tracks are never evicted.
///  - Among the rest, least-recently-used goes first (oldest [CachedTrack.
///    lastAccessedAt]; never-played counts as oldest), tie-broken by oldest
///    [CachedTrack.cachedAt] then track id for determinism.
///  - If even evicting every eligible track wouldn't make room, nothing is
///    evicted and the plan reports it doesn't fit.
class CacheEvictionPolicy {
  const CacheEvictionPolicy();

  EvictionPlan plan({
    required Iterable<CachedTrack> cached,
    required int incomingBytes,
    required int maxBytes,
    String? protectTrackId,
    String? incomingTrackId,
  }) {
    int used = 0;
    final List<CachedTrack> candidates = <CachedTrack>[];
    for (final CachedTrack track in cached) {
      // A re-download replaces its own old copy, so it doesn't count as
      // already-used space and can't evict itself.
      if (track.trackId == incomingTrackId) continue;
      used += track.sizeBytes;
      final bool evictable = track.isManaged &&
          track.sizeBytes > 0 &&
          !track.pinned &&
          track.trackId != protectTrackId;
      if (evictable) candidates.add(track);
    }

    if (used + incomingBytes <= maxBytes) return EvictionPlan.empty;

    // A single track larger than the whole limit can never fit, even in an
    // empty cache — refuse without evicting anything.
    if (incomingBytes > maxBytes) {
      return const EvictionPlan(evict: <CachedTrack>[], fits: false);
    }

    candidates.sort(_leastRecentlyUsedFirst);

    final List<CachedTrack> evict = <CachedTrack>[];
    int freed = 0;
    for (final CachedTrack track in candidates) {
      if (used - freed + incomingBytes <= maxBytes) break;
      evict.add(track);
      freed += track.sizeBytes;
    }

    final bool fits = used - freed + incomingBytes <= maxBytes;
    return fits
        ? EvictionPlan(evict: evict, fits: true)
        : const EvictionPlan(evict: <CachedTrack>[], fits: false);
  }

  static int _leastRecentlyUsedFirst(CachedTrack a, CachedTrack b) {
    final int byAccess = _compareNullableOldestFirst(
      a.lastAccessedAt,
      b.lastAccessedAt,
    );
    if (byAccess != 0) return byAccess;
    final int byCached = _compareNullableOldestFirst(a.cachedAt, b.cachedAt);
    if (byCached != 0) return byCached;
    return a.trackId.compareTo(b.trackId);
  }

  /// Orders two timestamps oldest-first, treating `null` (never accessed) as
  /// older than any real time so it's evicted before played tracks.
  static int _compareNullableOldestFirst(DateTime? a, DateTime? b) {
    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;
    return a.compareTo(b);
  }
}
