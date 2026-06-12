import '../../models/playback_source.dart';
import '../../models/track.dart';
import '../playable_uri_resolver.dart';
import 'remote_cache_entry.dart';
import 'remote_cache_key.dart';

/// The pure rules that govern the remote playback cache: what may be
/// prebuffered, what may be stored, how long it stays fresh, and whether a
/// stored entry may be reused.
///
/// Kept free of I/O and app state so the rules are exhaustively unit-testable
/// and shared verbatim by the read side ([RemoteCacheResolver]) and the write
/// side ([RemoteStreamPrebufferer]) — the two can never drift on eligibility or
/// TTL.
class RemoteCachePolicy {
  const RemoteCachePolicy({this.ttl = const Duration(minutes: 2)});

  /// How long a minted stream URL may be reused before the cache must resolve a
  /// fresh one. Short by design: a provider URL can be signed/expiring, so we
  /// would rather pay an occasional re-resolve than ever replay a stale URL.
  final Duration ttl;

  /// Whether [track] is a remote stream worth prebuffering. False for local
  /// files, `content://` documents, and anything tokenized — those are never
  /// touched by the cache.
  bool isPrebufferable(Track track) => RemoteCacheKey.isRemote(track);

  /// Whether a resolution with [source] is worth holding. Only a freshly-minted
  /// direct stream URL carries any benefit; a local path or an offline-cache hit
  /// opens instantly and must not be retained (and an offline copy is owned by
  /// the on-disk download cache, not this in-memory one).
  bool isStorable(PlaybackSource source) =>
      source == PlaybackSource.streamingDirect;

  /// Builds a fresh cache entry for [key] from a [resolved] playable, stamping
  /// [resolvedAt]/[expiresAt] from [now] and [ttl].
  RemoteCacheEntry buildEntry({
    required RemoteCacheKey key,
    required ResolvedPlayable resolved,
    required DateTime now,
  }) =>
      RemoteCacheEntry(
        key: key,
        streamUri: resolved.uri,
        source: resolved.source,
        resolvedAt: now,
        expiresAt: now.add(ttl),
      );

  /// Whether a stored [entry] may still be served at [now]. A stale entry must
  /// be dropped and re-resolved instead of replayed.
  bool shouldReuse(RemoteCacheEntry entry, DateTime now) => entry.isFresh(now);
}
