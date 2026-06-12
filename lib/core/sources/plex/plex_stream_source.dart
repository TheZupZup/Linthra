import '../../models/track.dart';

/// The narrow capability the playback resolver needs from a signed-in Plex
/// connection: confirm the session still works, then mint a stream URL.
///
/// [PlexMusicSource] implements it; keeping it tiny lets the future resolver
/// depend on just this (not the whole source or any HTTP), and lets tests fake
/// the source directly to drive every outcome — expired token, unreachable
/// server, a vanished item — without a real server. Mirrors
/// `JellyfinStreamSource`; phase 1 is stream-only (no offline cache), so unlike
/// `SubsonicStreamSource` there is no download seam to expose.
///
/// Security: a Plex stream URL carries the `X-Plex-Token` in its **query** (the
/// audio engine can't set headers), so it is minted here on demand, at play
/// time, and never stored on [track]. See docs/plex.md → Token safety rules.
abstract interface class PlexStreamSource {
  /// Confirms the session is still valid and the server reachable. Throws a
  /// `PlexException` (unauthorized / not reachable / …) when it is not.
  Future<void> verifyReachable();

  /// The tokenized stream URL for [track], or `null` when one cannot be built
  /// (the item carries no playable part). The token is woven in here, on
  /// demand, and never stored on [track].
  Future<Uri?> resolvePlayableUri(Track track);
}
