/// Remembers which origin the references saved before origins were recorded
/// belong to, one per bound scheme (see `SongOrigins.legacy`).
///
/// Settled once and kept: deciding again later could hand an older reference
/// to whichever account signed in since, the very thing the origins are for.
abstract interface class SongOriginLegacyStore {
  /// The settled origin by uri scheme (`subsonic:`), `''` for a scheme whose
  /// older references belong to nobody. A scheme with no entry isn't settled.
  Future<Map<String, String>> read();

  /// Saves [settled], replacing what was there.
  Future<void> write(Map<String, String> settled);
}
