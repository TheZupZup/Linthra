import '../../models/cast_media.dart';
import '../../models/track.dart';

/// Why resolving a [Track] into castable media failed.
enum CastMediaErrorKind {
  /// No signed-in account backs this track's source (e.g. a Jellyfin track but
  /// no Jellyfin session), so a reachable URL can't be minted.
  notSignedIn,

  /// The source was reachable/authorized, but no castable URL is available for
  /// this track right now (server error, expired session, non-audio response…).
  unavailable,
}

/// A typed, user-facing failure raised while resolving a [Track] into a
/// [CastMedia].
///
/// Security invariant (identical to `PlaybackResolutionException`): [message]
/// must NEVER contain an access token or an authenticated URL — only generic,
/// safe text the sheet can show.
class CastMediaException implements Exception {
  const CastMediaException(this.message, {required this.kind});

  final String message;
  final CastMediaErrorKind kind;

  @override
  String toString() => message;
}

/// Resolves a [Track] into [CastMedia] a receiver can fetch, on demand at cast
/// time.
///
/// This is the cast-side counterpart to `PlayableUriResolver`: that one yields a
/// `file://`/`content://`/`https://` URI for the on-device audio engine, while
/// this one yields only a *network-reachable* URL (the receiver fetches it
/// itself). [canCast] reports whether a track has any castable form at all —
/// false for on-device files, which have no URL a receiver could reach — so the
/// caller can show a clear limitation instead of attempting (and failing) to
/// cast them.
abstract interface class CastMediaResolver {
  /// Whether [track] could be cast at all (i.e. has a network source). False
  /// for purely on-device files.
  bool canCast(Track track);

  /// Resolves [track] into castable media, minting any token-bearing URL on
  /// demand, or throws a [CastMediaException] with a friendly, secret-free
  /// message. Only call when [canCast] is true.
  Future<CastMedia> resolve(Track track);
}
