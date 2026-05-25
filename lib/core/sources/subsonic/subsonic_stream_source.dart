import '../../models/track.dart';

/// The narrow capability the playback resolver, cast resolver, and offline
/// downloader need from a signed-in Subsonic connection: confirm the session
/// still works, then mint a stream or download URL on demand.
///
/// [SubsonicMusicSource] implements it; keeping it tiny lets each consumer
/// depend on just this (not the whole source or any HTTP) and lets tests fake
/// the source directly to drive every outcome — expired session, unreachable
/// server, unavailable stream — without a real server.
///
/// Security: the URLs carry the salt+token in their query, so they are minted
/// here on demand, at play/download time, and never stored on [track].
abstract interface class SubsonicStreamSource {
  /// Confirms the session is still valid and the server reachable. Throws a
  /// `SubsonicException` (unauthorized / not reachable / …) when it is not.
  Future<void> verifyReachable();

  /// The authenticated stream URL for [track], or `null` when one cannot be
  /// built. The credential is woven in here, on demand, never stored on [track].
  Future<Uri?> resolvePlayableUri(Track track);

  /// The authenticated URL to download [track]'s original file, or `null` when
  /// one can't be built. The credential is woven in on demand, never stored.
  Future<Uri?> resolveDownloadUri(Track track);
}
