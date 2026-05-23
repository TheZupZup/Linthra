import '../../models/track.dart';

/// The narrow capability the playback resolver needs from a signed-in Jellyfin
/// connection: confirm the session still works, then mint a stream URL.
///
/// [JellyfinMusicSource] implements it; keeping it tiny lets the resolver
/// depend on just this (not the whole source or any HTTP), and lets tests fake
/// the source directly to drive every outcome — expired session, unreachable
/// server, and an unavailable stream — without a real server.
abstract interface class JellyfinStreamSource {
  /// Confirms the session is still valid and the server reachable. Throws a
  /// `JellyfinException` (unauthorized / not reachable / …) when it is not.
  Future<void> verifyReachable();

  /// The authenticated stream URL for [track], or `null` when one cannot be
  /// built. The token is woven in here, on demand, and never stored on [track].
  Future<Uri?> resolvePlayableUri(Track track);
}
