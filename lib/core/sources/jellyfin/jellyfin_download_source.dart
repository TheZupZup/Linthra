import '../../models/track.dart';

/// The narrow capability the offline downloader needs from a signed-in Jellyfin
/// connection: confirm the session works, then mint a *download* URL for a
/// track's original file.
///
/// The mirror image of [JellyfinStreamSource] (which mints a *stream* URL).
/// [JellyfinMusicSource] implements both; keeping this tiny lets the downloader
/// depend on just this — not the whole source or any HTTP — and lets tests fake
/// it to drive every download outcome without a real server.
///
/// Security: [resolveDownloadUri] weaves the access token into the URL on
/// demand, at download time, and the URL is never stored on [track] or anywhere
/// else.
abstract interface class JellyfinDownloadSource {
  /// Confirms the session is still valid and the server reachable. Throws a
  /// `JellyfinException` (unauthorized / not reachable / …) when it is not.
  Future<void> verifyReachable();

  /// The authenticated URL to download [track]'s original file, or `null` when
  /// one can't be built. The token is woven in here, on demand, never stored.
  Future<Uri?> resolveDownloadUri(Track track);
}
