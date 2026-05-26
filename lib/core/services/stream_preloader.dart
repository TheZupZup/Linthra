import '../models/track.dart';

/// Warms an upcoming **remote** track's stream URL into memory so a skip to it
/// starts faster — it skips the play-time session check + URL probe round-trips
/// that otherwise run at each track change.
///
/// This is **not** the offline cache. Preloading:
///  - never writes bytes to disk and never marks a track as downloaded,
///  - holds only a short-lived, in-memory resolution that is consumed on first
///    use,
///  - is best-effort and must never throw or interrupt the current track,
///  - never logs or surfaces the token-bearing URL it resolves.
///
/// `StreamPreloadingResolver` implements it alongside `PlayableUriResolver`, so
/// the same in-memory cache it warms is the one the playback controller reads at
/// play time.
abstract interface class StreamPreloader {
  /// Best-effort: resolve [track]'s stream URL ahead of time and hold it briefly
  /// in memory. A no-op for non-remote tracks and on any failure. Never throws.
  Future<void> preload(Track track);
}
