import 'remote_cache_record.dart';

/// Durable storage for the remote playback cache's **credential-free** index.
///
/// This is the persistence seam under [RemoteCacheIndex] — the on-disk half of
/// the cache the in-memory [RemotePlaybackCache] was built as a seam for. It
/// knows nothing about prebuffering, freshness, or providers; it only loads and
/// saves a flat list of [RemoteCacheRecord]s.
///
/// Security contract: every record it round-trips is credential-free by
/// construction (see [RemoteCacheRecord]). A store implementation must therefore
/// never be handed — and can never obtain — a stream URL or a token; the only
/// thing it ever writes is the opaque key + timestamps. Splitting it behind an
/// interface keeps [RemoteCacheIndex] pure and testable (an in-memory fake) and
/// lets the backing store swap freely (a JSON manifest on disk in the app, a
/// fake in tests).
abstract interface class RemoteCacheStore {
  /// The records currently persisted. Returns an empty list (never throws) when
  /// there is nothing stored or the backing data is unreadable, so a corrupt
  /// manifest degrades to "cold cache" rather than breaking startup.
  Future<List<RemoteCacheRecord>> load();

  /// Replaces the persisted set with [records]. Best-effort: a failed write must
  /// not be fatal to the caller (the [RemoteCacheIndex] swallows it), since the
  /// index is a convenience and never on the playback path.
  Future<void> save(List<RemoteCacheRecord> records);
}
