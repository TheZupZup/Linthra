import 'remote_cache_entry.dart';
import 'remote_cache_key.dart';

/// The cleanup rules for temporary prebuffer/cache data.
///
/// Pure and I/O-free: it takes the current entries and the clock and reports
/// which keys should be dropped, so the rules are exhaustively testable and the
/// store ([RemotePlaybackCache]) stays free of branching policy. Today the only
/// rule is "drop expired entries", which keeps the in-memory cache from holding
/// stale (and possibly expired) stream URLs past their freshness window — the
/// seam where an on-disk eviction sweep will later hang off the same contract.
class RemoteCacheCleanup {
  const RemoteCacheCleanup();

  /// The keys of every entry that is no longer fresh at [now].
  Iterable<RemoteCacheKey> expiredKeys(
    Iterable<RemoteCacheEntry> entries,
    DateTime now,
  ) =>
      entries
          .where((RemoteCacheEntry entry) => !entry.isFresh(now))
          .map((RemoteCacheEntry entry) => entry.key);
}
