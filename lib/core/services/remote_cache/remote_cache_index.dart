import 'remote_cache_entry.dart';
import 'remote_cache_record.dart';
import 'remote_cache_store.dart';

/// The durable, **credential-free** index of the remote playback cache.
///
/// The in-memory [RemotePlaybackCache] forgets everything when the process ends
/// (and holds the token-bearing stream URL only for its short TTL). This index
/// is its on-disk complement: as the prebufferer warms a remote track it records
/// the track's credential-free identity ([RemoteCacheRecord] — key + timestamps,
/// never the URL) through a [RemoteCacheStore], so the cache's *knowledge*
/// survives a restart even though the (expiring, tokenized) URL deliberately
/// does not. This is the seam the future on-disk byte cache and its eviction
/// sweep hang off; persisting no URL is also what guarantees a provider stream
/// is always re-resolved fresh after a restart rather than replayed stale.
///
/// Everything here is **best-effort and non-fatal**, mirroring the prebufferer
/// it rides behind: every store interaction is wrapped, so a slow or failing
/// disk can never throw into the playback path. Reads load lazily exactly once
/// (so a record can't race ahead of the initial load and be clobbered by it),
/// and a record only ever carries a credential-free [RemoteCacheRecord], so no
/// secret can reach disk, a filename, a log line, or a diagnostics string.
class RemoteCacheIndex {
  RemoteCacheIndex({
    required RemoteCacheStore store,
    Duration retention = const Duration(days: 30),
    int maxEntries = 1024,
    DateTime Function()? clock,
  })  : _store = store,
        _retention = retention,
        _maxEntries = maxEntries,
        _now = clock ?? DateTime.now;

  final RemoteCacheStore _store;
  final Duration _retention;

  /// An upper bound on the number of records so the manifest — and every
  /// rewrite — stays small no matter how many tracks are played over the
  /// retention window. The oldest-recorded entries are evicted first.
  final int _maxEntries;

  final DateTime Function() _now;

  /// Keyed by the credential-free [RemoteCacheRecord.value]. Never holds a URL.
  final Map<String, RemoteCacheRecord> _records = <String, RemoteCacheRecord>{};

  /// Memoizes the one-shot load so every caller (startup, the first record)
  /// awaits the same completed load before touching [_records].
  Future<void>? _loadFuture;

  /// Loads the persisted index (merging the freshest record per key and dropping
  /// anything already expired), then prunes and rewrites it. Idempotent: the
  /// underlying read runs at most once for the life of the index.
  Future<void> load() => _ensureLoaded();

  /// Records [entry]'s credential-free identity into the index and persists.
  /// Best-effort: a failure (a full disk, a denied write) is swallowed, so a
  /// warm that can't be remembered simply isn't — playback is untouched.
  Future<void> record(RemoteCacheEntry entry) async {
    try {
      await _ensureLoaded();
      final DateTime now = _now();
      _records[entry.key.value] = RemoteCacheRecord.fromEntry(
        entry,
        recordedAt: now,
        expiresAt: now.add(_retention),
      );
      _enforceCap();
      await _persist();
    } catch (_) {
      // Non-fatal: the index is a convenience, never required for playback.
    }
  }

  /// Drops every record past its retention window and persists the pruned set.
  /// The cleanup rule for the durable cache, kept on the same freshness contract
  /// as the in-memory sweep; a sweep that removes nothing writes nothing.
  ///
  /// Startup [load] already prunes, so a cold start needs no separate sweep;
  /// this is the explicit re-sweep hook for a long-running session (or a future
  /// periodic cleanup), and it is what keeps `sweep` parallel to the in-memory
  /// `RemotePlaybackCache.sweep`.
  Future<void> sweep() async {
    try {
      await _ensureLoaded();
      if (_pruneExpired(_now())) await _persist();
    } catch (_) {
      // Non-fatal.
    }
  }

  /// Empties the index and the persisted store. The reset hook a sign-out flow
  /// should call so a previous account's prepared-track list is not retained —
  /// provided as a lifecycle method like the in-memory `RemotePlaybackCache.clear`
  /// (which the sign-out flows likewise own). The records are credential-free, so
  /// this is hygiene rather than a secret-safety requirement.
  Future<void> clear() async {
    _records.clear();
    try {
      await _store.save(const <RemoteCacheRecord>[]);
    } catch (_) {
      // Non-fatal.
    }
  }

  /// A snapshot of the indexed records — credential-free, for tests/diagnostics.
  List<RemoteCacheRecord> get records =>
      List<RemoteCacheRecord>.of(_records.values);

  /// The number of indexed records.
  int get length => _records.length;

  Future<void> _ensureLoaded() => _loadFuture ??= _load();

  Future<void> _load() async {
    try {
      final List<RemoteCacheRecord> stored = await _store.load();
      // _ensureLoaded memoizes this load and every writer awaits it first, so
      // _records is empty here and a plain assign is enough (a manifest the app
      // wrote is itself keyed by value, so it carries no duplicate keys).
      for (final RemoteCacheRecord record in stored) {
        _records[record.value] = record;
      }
      // Normalize the on-disk form only if loading actually changed it (dropped
      // a stale record or trimmed to the cap), so a clean manifest does no
      // redundant write.
      final bool pruned = _pruneExpired(_now());
      final bool capped = _enforceCap();
      if (pruned || capped) await _persist();
    } catch (_) {
      // Non-fatal: an unreadable store just means a cold index.
    }
  }

  /// Removes every record past its freshness window; returns whether any were
  /// dropped, so callers can skip a redundant persist when nothing changed.
  bool _pruneExpired(DateTime now) {
    final int before = _records.length;
    _records.removeWhere(
      (_, RemoteCacheRecord record) => !record.isFresh(now),
    );
    return _records.length != before;
  }

  /// Bounds the index to [_maxEntries], evicting the oldest-recorded entries
  /// first so the manifest stays small; returns whether any were evicted.
  bool _enforceCap() {
    if (_records.length <= _maxEntries) return false;
    final List<RemoteCacheRecord> byAge = _records.values.toList()
      ..sort((RemoteCacheRecord a, RemoteCacheRecord b) =>
          a.recordedAt.compareTo(b.recordedAt));
    bool evicted = false;
    for (final RemoteCacheRecord record in byAge) {
      if (_records.length <= _maxEntries) break;
      _records.remove(record.value);
      evicted = true;
    }
    return evicted;
  }

  Future<void> _persist() async {
    try {
      await _store.save(_records.values.toList(growable: false));
    } catch (_) {
      // Non-fatal.
    }
  }
}
