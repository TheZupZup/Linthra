import '../../models/track.dart';
import '../playable_uri_resolver.dart';
import 'remote_cache_entry.dart';
import 'remote_cache_key.dart';
import 'remote_cache_policy.dart';
import 'remote_playback_cache.dart';

/// The **read side** of the remote playback cache: a [PlayableUriResolver] that
/// serves a prebuffered stream URL when one is fresh, and otherwise delegates to
/// the wrapped resolver.
///
/// It pairs with [RemoteStreamPrebufferer] over a shared [RemotePlaybackCache]:
/// the prebufferer warms upcoming remote URLs into the cache, and this resolver
/// consumes them on the next play so a skip or track change doesn't pay the
/// session-check + URL-mint latency again.
///
/// Two safety properties it preserves verbatim from the previous in-line
/// preloader:
///  - **Consume-on-read.** A warmed URL is served at most once; a retry after a
///    failed load (or a later replay of the same track) re-resolves a fresh URL
///    rather than replaying a possibly-expired one.
///  - **Freshness-gated.** An expired entry is ignored, so a stale provider URL
///    is never handed to the engine.
///  - **Account-bound.** An entry is only served while the account it was
///    minted for is still signed in ([accountScopeOf]). After a sign-out, or
///    with another account in its place, the track resolves through the
///    wrapped resolver, which says "sign in" or mints the new account's URL,
///    instead of playing with the old account's credentials.
///
/// A non-remote track (local file, `content://`) has no cache key, so it always
/// falls straight through to the inner resolver.
class RemoteCacheResolver implements PlayableUriResolver {
  RemoteCacheResolver({
    required PlayableUriResolver inner,
    required RemotePlaybackCache cache,
    RemoteCachePolicy policy = const RemoteCachePolicy(),
    DateTime Function()? clock,
    String? Function(Track track)? accountScopeOf,
  })  : _inner = inner,
        _cache = cache,
        _policy = policy,
        _now = clock ?? DateTime.now,
        _accountScopeOf = accountScopeOf;

  final PlayableUriResolver _inner;
  final RemotePlaybackCache _cache;
  final RemoteCachePolicy _policy;
  final DateTime Function() _now;

  /// The non-secret identity of the account [Track]'s provider is signed in
  /// with right now, or null when signed out. Null when not wired (tests),
  /// where every entry counts as the one account's.
  final String? Function(Track track)? _accountScopeOf;

  @override
  bool handles(Track track) => _inner.handles(track);

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    final RemoteCacheKey? key = RemoteCacheKey.forTrack(track);
    if (key != null) {
      final DateTime now = _now();
      // Consumed either way: an entry minted for another account is of no
      // use to anyone after this and is dropped here.
      final RemoteCacheEntry? entry = _cache.consume(key, now);
      if (entry != null &&
          _policy.shouldReuse(
            entry,
            now,
            accountScope: accountScopeFor(_accountScopeOf, track),
          )) {
        return ResolvedPlayable(entry.streamUri, entry.source);
      }
    }
    return _inner.resolve(track);
  }
}

/// Asks [scopeOf] for [track]'s account. A check that throws reads as signed
/// out, so it can never vouch for an entry.
String? accountScopeFor(String? Function(Track track)? scopeOf, Track track) {
  if (scopeOf == null) return null;
  try {
    return scopeOf(track);
  } catch (_) {
    return null;
  }
}
