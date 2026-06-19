import '../../models/track.dart';

/// The narrow capability the offline downloader needs from a signed-in Plex
/// connection: confirm the session works, then mint a *download* URL for a
/// track's original media file.
///
/// The mirror image of [PlexStreamSource] (which mints a *stream* URL), and the
/// Plex counterpart to [JellyfinDownloadSource]. [PlexMusicSource] implements
/// both; keeping this tiny lets the downloader depend on just this — not the
/// whole source or any HTTP — and lets tests fake it to drive every download
/// outcome (expired token, unreachable server, a vanished item, a part-less
/// item) without a real server.
///
/// Security: a Plex download URL carries the `X-Plex-Token` in its **query**
/// (the HTTP fetch can't set headers), so [resolveDownloadUri] weaves it in on
/// demand, at download time, and the URL is never stored on [track] — exactly
/// like the stream URL. See docs/plex.md → Token safety rules.
abstract interface class PlexDownloadSource {
  /// Confirms the session is still valid and the server reachable. Throws a
  /// `PlexException` (unauthorized / not reachable / …) when it is not.
  Future<void> verifyReachable();

  /// The authenticated URL to download [track]'s original file, or `null` when
  /// one can't be built (the item carries no playable part). The token is woven
  /// in here, on demand, never stored on [track].
  Future<Uri?> resolveDownloadUri(Track track);
}
