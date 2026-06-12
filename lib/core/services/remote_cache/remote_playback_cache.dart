import 'remote_cache_cleanup.dart';
import 'remote_cache_entry.dart';
import 'remote_cache_key.dart';

/// The in-memory store of prebuffered remote stream resolutions, shared by the
/// prebufferer (write side) and the cache-backed resolver (read side).
///
/// Provider-neutral and credential-safe by construction:
///  - It holds [RemoteCacheEntry] values keyed by a **credential-free**
///    [RemoteCacheKey]; the token-bearing `streamUri` lives only inside an entry,
///    in memory.
///  - It **persists nothing** — there is no serialization here. The whole store
///    is dropped when the process ends (and swept of stale entries as it runs),
///    so a tokenized URL can never outlive the session or reach disk.
///
/// Freshness is enforced on every read: an expired entry is treated as absent
/// (and removed), so a stale URL is never served — the caller resolves a fresh
/// one instead.
class RemotePlaybackCache {
  RemotePlaybackCache({RemoteCacheCleanup cleanup = const RemoteCacheCleanup()})
      : _cleanup = cleanup;

  final RemoteCacheCleanup _cleanup;

  /// Keyed by the credential-free [RemoteCacheKey.value]. Never serialized.
  final Map<String, RemoteCacheEntry> _entries = <String, RemoteCacheEntry>{};

  /// Stores (or replaces) the entry for its key. The newest resolution wins.
  void store(RemoteCacheEntry entry) {
    _entries[entry.key.value] = entry;
  }

  /// Whether a *fresh* entry exists for [key] at [now], without consuming it —
  /// used to avoid re-resolving something already warm.
  bool contains(RemoteCacheKey key, DateTime now) {
    final RemoteCacheEntry? entry = _entries[key.value];
    return entry != null && entry.isFresh(now);
  }

  /// Returns the fresh entry for [key] at [now] without removing it; drops it if
  /// stale. Prefer [consume] for the play path so a URL is reused only once.
  RemoteCacheEntry? peek(RemoteCacheKey key, DateTime now) {
    final RemoteCacheEntry? entry = _entries[key.value];
    if (entry == null) return null;
    if (!entry.isFresh(now)) {
      _entries.remove(key.value);
      return null;
    }
    return entry;
  }

  /// Removes and returns the fresh entry for [key] at [now], or `null` if none
  /// is fresh. Consume-on-read is what lets a retry or a later replay of the
  /// same track re-resolve a fresh URL rather than reuse a possibly-expired one.
  RemoteCacheEntry? consume(RemoteCacheKey key, DateTime now) {
    final RemoteCacheEntry? entry = _entries.remove(key.value);
    if (entry == null || !entry.isFresh(now)) return null;
    return entry;
  }

  /// Drops every entry that is no longer fresh at [now], per [RemoteCacheCleanup].
  void sweep(DateTime now) {
    final List<RemoteCacheKey> stale =
        _cleanup.expiredKeys(_entries.values.toList(), now).toList();
    for (final RemoteCacheKey key in stale) {
      _entries.remove(key.value);
    }
  }

  /// Discards everything (e.g. on sign-out, so no warmed URL outlives a session).
  void clear() => _entries.clear();

  /// The number of stored entries (fresh or not) — for tests/diagnostics counts;
  /// never exposes a URL.
  int get length => _entries.length;
}
