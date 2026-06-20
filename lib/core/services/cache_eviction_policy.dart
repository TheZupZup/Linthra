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
/// Provider-agnostic but provider-aware: it ranks and evicts cached tracks from
/// every remote source together (Jellyfin, Subsonic/Navidrome, Plex) by the same
/// rules, and identifies the incoming and protected tracks by the provider-aware
/// [CachedTrack.cacheKey] (`scheme + id`), so two providers that expose the same
/// catalog id never shadow, protect, or evict each other. A legacy record that
/// predates `sourceType` (no provider) falls back to a bare-id match, so an
/// upgrading user's currently playing legacy track is still protected.
///
/// Rules, in order:
///  - On-device tracks and zero-byte records don't count toward the budget and
///    are never evicted (they hold no app-managed bytes).
///  - The currently playing track is never evicted.
///  - Pinned ("Keep offline") tracks are never evicted.
///  - Auto-preloaded tracks go before any user download: a prefetched copy is a
///    convenience, so it's sacrificed first to keep what the user chose to keep.
///  - Among entries of the same kind, least-recently-used goes first (oldest
///    [CachedTrack.lastAccessedAt]; never-played counts as oldest), tie-broken by
///    oldest [CachedTrack.cachedAt] then track id for determinism.
///  - If even evicting every eligible track wouldn't make room, nothing is
///    evicted and the plan reports it doesn't fit.
class CacheEvictionPolicy {
  const CacheEvictionPolicy();

  EvictionPlan plan({
    required Iterable<CachedTrack> cached,
    required int incomingBytes,
    required int maxBytes,
    String? protectKey,
    String? incomingKey,
  }) {
    int used = 0;
    final List<CachedTrack> candidates = <CachedTrack>[];
    for (final CachedTrack track in cached) {
      // A re-download replaces its own old copy, so it doesn't count as
      // already-used space and can't evict itself. Matched provider-aware (see
      // [_matchesLiveTrack]), so a same-id track from a *different* provider is
      // never mistaken for the incoming track's copy.
      if (_matchesLiveTrack(track, incomingKey)) continue;
      used += track.sizeBytes;
      final bool evictable = track.isManaged &&
          track.sizeBytes > 0 &&
          !track.pinned &&
          !_matchesLiveTrack(track, protectKey);
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

  /// Whether [track] is the cache slot for the live track identified by [key]
  /// (its provider-aware [CachedTrack.cacheKey]).
  ///
  /// A record written before `sourceType` existed has no provider, so it can't
  /// carry the provider-aware key — it's matched by the bare id encoded in
  /// [key] instead, so an upgrading user's currently playing (or re-downloading)
  /// legacy track is still recognised and protected. An entry that *does* carry
  /// a sourceType is matched strictly, preserving same-id cross-provider
  /// isolation.
  static bool _matchesLiveTrack(CachedTrack track, String? key) {
    if (key == null) return false;
    if (track.cacheKey == key) return true;
    return track.sourceType == null &&
        track.trackId == CachedTrack.trackIdFromKey(key);
  }

  static int _leastRecentlyUsedFirst(CachedTrack a, CachedTrack b) {
    // Auto-preloaded entries are evicted before any user download.
    if (a.preloaded != b.preloaded) return a.preloaded ? -1 : 1;
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
