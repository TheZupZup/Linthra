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
/// catalog id never shadow, protect, or evict each other.
///
/// Rules, in order:
///  - On-device tracks and zero-byte records don't count toward the budget and
///    are never evicted (they hold no app-managed bytes).
///  - The currently playing track is never evicted.
///  - Any other key the caller protects (the tracks about to play) is never
///    evicted either, so warming the third upcoming track can't throw away the
///    first one it warmed a moment ago.
///  - Pinned ("Keep offline") tracks are never evicted.
///  - With [plan]'s `onlyPreloaded`, only auto-preloaded entries are candidates:
///    an automatic pre-cache makes room from other pre-caches or not at all, and
///    never removes a track the user downloaded, pinned or not.
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
    Set<String> protectKeys = const <String>{},
    bool onlyPreloaded = false,
    String? incomingKey,
  }) {
    int used = 0;
    final List<CachedTrack> candidates = <CachedTrack>[];
    for (final CachedTrack track in cached) {
      // A re-download replaces its own old copy, so it doesn't count as
      // already-used space and can't evict itself. Keyed by the provider-aware
      // [CachedTrack.cacheKey] (scheme + id), so a same-id track from a
      // *different* provider is never mistaken for the incoming track's copy.
      if (track.cacheKey == incomingKey) continue;
      used += track.sizeBytes;
      if (isEvictable(
        track,
        protectKey: protectKey,
        protectKeys: protectKeys,
        onlyPreloaded: onlyPreloaded,
      )) {
        candidates.add(track);
      }
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

  /// Whether [track] may be removed to make room, under the same rules [plan]
  /// applies. Public so a caller deciding whether a best-effort pre-cache is
  /// worth fetching at all asks exactly the question the commit will ask.
  static bool isEvictable(
    CachedTrack track, {
    String? protectKey,
    Set<String> protectKeys = const <String>{},
    bool onlyPreloaded = false,
  }) =>
      track.isManaged &&
      track.sizeBytes > 0 &&
      !track.pinned &&
      (!onlyPreloaded || track.preloaded) &&
      track.cacheKey != protectKey &&
      !protectKeys.contains(track.cacheKey);

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
