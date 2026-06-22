import 'reachability.dart';

/// A short-lived, per-provider memory of the last reachability outcome, so the
/// app can stop hammering a server that just failed and instead fall straight to
/// a cached or alternate copy.
///
/// Why this exists: playing an album from a server that's gone offline would,
/// without a memory, re-run the full session-check + connect timeout for *every*
/// track — a 10–20 s stall before each fallback. Recording the first failure
/// lets the next few tracks skip the doomed probe entirely. The memory is
/// deliberately **brief** (a handful of seconds): long enough to cover a burst
/// of tracks, short enough that a server coming back is retried almost
/// immediately — so "retry after connectivity returns" needs no manual reset.
///
/// Keys are caller-defined and are expected to be *provider-namespaced* (e.g.
/// `jellyfin`, `subsonic`, `plex`), never a bare track id. That keeps two
/// providers that happen to share a server-side id (`jellyfin:101` vs
/// `subsonic:101`) fully isolated: marking one provider unreachable never
/// suppresses the other's copy. This mirrors the provider-aware identity model
/// the catalog and prefs already use.
abstract interface class ProviderReachability {
  /// The remembered status for [key], or `null` when nothing is remembered or
  /// the remembered value has aged out. Never performs a network probe.
  ReachabilityStatus? statusOf(String key);

  /// Remembers [status] for [key], (re)starting its short time-to-live. A later
  /// [reachable] overwrites an earlier outage, so a recovered server is trusted
  /// again immediately rather than waiting out the previous failure's TTL.
  void record(String key, ReachabilityStatus status);

  /// Forgets any remembered status for [key] — e.g. on sign-out or a server
  /// change, where a stale outage must not carry over to a new session.
  void forget(String key);

  /// Forgets every remembered status.
  void clear();
}

/// In-memory [ProviderReachability] with a per-entry time-to-live.
///
/// Holds only a tiny map of `key -> (status, recordedAt)` on the heap; nothing
/// is persisted, so a restart starts fresh (the safe default — it just re-probes
/// once). The [clock] is injectable so tests can advance time deterministically
/// without sleeping, and so the TTL logic is exercised without flakiness.
class CachingProviderReachability implements ProviderReachability {
  CachingProviderReachability({
    Duration ttl = const Duration(seconds: 10),
    DateTime Function()? clock,
  })  : _ttl = ttl,
        _now = clock ?? DateTime.now;

  /// How long a remembered status stays valid. Short by design: it only needs to
  /// span a burst of plays (an album), not a long absence — a server that
  /// recovers should be retried within a few seconds, not minutes.
  final Duration _ttl;
  final DateTime Function() _now;

  final Map<String, _Entry> _entries = <String, _Entry>{};

  @override
  ReachabilityStatus? statusOf(String key) {
    final _Entry? entry = _entries[key];
    if (entry == null) return null;
    if (_now().difference(entry.recordedAt) >= _ttl) {
      // Aged out: drop it so the map can't grow without bound, and report
      // "unknown" so the caller probes for a fresh answer.
      _entries.remove(key);
      return null;
    }
    return entry.status;
  }

  @override
  void record(String key, ReachabilityStatus status) {
    _entries[key] = _Entry(status, _now());
  }

  @override
  void forget(String key) {
    _entries.remove(key);
  }

  @override
  void clear() {
    _entries.clear();
  }
}

/// A remembered status and when it was recorded, for TTL comparison.
class _Entry {
  _Entry(this.status, this.recordedAt);

  final ReachabilityStatus status;
  final DateTime recordedAt;
}
