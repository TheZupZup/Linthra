import '../../models/track.dart';

/// The narrow capability the offline downloader needs from a signed-in Plex
/// connection: confirm the session still works, then mint a tokenized direct
/// file URL for a track's original `Part`.
///
/// Mirrors `JellyfinDownloadSource`. [PlexMusicSource] implements it so the
/// offline cache can fetch Plex bytes without knowing anything about Plex HTTP,
/// sessions, or token handling.
///
/// Security: Plex file URLs carry `X-Plex-Token` in their query because the
/// cache downloader fetches raw bytes with a plain HTTP request. The URL is
/// minted only at download time and must never be stored on [track], cached in
/// metadata, logged, or surfaced in thrown errors.
abstract interface class PlexDownloadSource {
  /// Confirms the session is still valid and the server reachable. Throws a
  /// token-free `PlexException` when it is not.
  Future<void> verifyReachable();

  /// The tokenized URL to download [track]'s original file, or `null` when the
  /// Plex item carries no playable/downloadable part.
  Future<Uri?> resolveDownloadUri(Track track);
}
