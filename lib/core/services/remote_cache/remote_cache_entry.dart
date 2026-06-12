import '../../models/playback_source.dart';
import 'remote_cache_key.dart';

/// One prebuffered remote resolution held in the [RemotePlaybackCache].
///
/// Security split, deliberate and load-bearing:
///  - [key], [source], and the timestamps are **credential-free metadata** —
///    safe to log, persist, and (via [RemoteCacheKey.fileSafeName]) name a file.
///  - [streamUri] is the freshly-minted, **token-bearing** stream URL. It lives
///    here in memory only. It is never serialized, never logged, never put in a
///    filename, and never surfaced in an error or diagnostics. The exposed
///    [diagnosticLabel] omits it for exactly this reason.
///
/// An entry is short-lived: [expiresAt] bounds how long the (possibly
/// signed/expiring) [streamUri] may be reused before the cache must resolve a
/// fresh one instead of replaying a stale one.
class RemoteCacheEntry {
  const RemoteCacheEntry({
    required this.key,
    required this.streamUri,
    required this.source,
    required this.resolvedAt,
    required this.expiresAt,
  });

  /// The credential-free identity of the cached track.
  final RemoteCacheKey key;

  /// The minted, authenticated stream URL. **In-memory only** — must never be
  /// persisted, logged, or exposed.
  final Uri streamUri;

  /// Where the bytes come from. Only [PlaybackSource.streamingDirect] is ever
  /// stored (see `RemoteCachePolicy.isStorable`); the field is kept so the
  /// player can badge the source without re-deriving it.
  final PlaybackSource source;

  /// When this resolution was minted.
  final DateTime resolvedAt;

  /// When it goes stale and must not be reused.
  final DateTime expiresAt;

  /// Whether the entry is still within its freshness window at [now].
  bool isFresh(DateTime now) => now.isBefore(expiresAt);

  /// A credential-free, one-line description safe for logs and diagnostics.
  /// Deliberately excludes [streamUri] (which carries the token).
  String get diagnosticLabel => 'remote-cache[$key src=${source.name}]';
}
