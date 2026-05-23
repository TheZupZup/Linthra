import '../models/track.dart';

/// Why resolving a [Track] to a playable URI failed.
///
/// Lets the player surface a specific, user-friendly message — and lets tests
/// assert the *kind* of failure — without matching on message text.
enum PlaybackResolutionErrorKind {
  /// No signed-in account backs this track's source (e.g. a Jellyfin track but
  /// no Jellyfin session).
  notSignedIn,

  /// The source rejected the session — the token is no longer valid.
  sessionExpired,

  /// The source could not be reached (offline, server down, bad address).
  serverUnreachable,

  /// The source is reachable and authorized, but no playable URL is available
  /// for this track right now.
  streamUnavailable,
}

/// A typed, user-facing failure raised while resolving a [Track] to a URI the
/// audio engine can open.
///
/// Security invariant: a [message] must NEVER contain an access token or the
/// authenticated streaming URL. Construct it only with generic, safe text — the
/// resolver that throws it supplies wording appropriate to its source.
class PlaybackResolutionException implements Exception {
  const PlaybackResolutionException(this.message, {required this.kind});

  /// A user-facing explanation safe to show in the UI.
  final String message;

  /// What broadly went wrong, for the UI to branch on.
  final PlaybackResolutionErrorKind kind;

  @override
  String toString() => message;
}

/// Resolves a [Track] to a URI the audio backend can actually open.
///
/// This is the seam the playback controller uses instead of assuming every
/// track is a local file path. Each implementation handles one family of tracks
/// (local files, Jellyfin items, …); a routing resolver composes them. Keeping
/// resolution out of the engine adapter means remote URL minting — and the
/// secrets it weaves in — never lives in the audio layer.
abstract interface class PlayableUriResolver {
  /// Whether this resolver can produce a URI for [track].
  bool handles(Track track);

  /// Resolves [track] to a playable URI, or throws a
  /// [PlaybackResolutionException] with a friendly, secret-free message.
  Future<Uri> resolve(Track track);
}
