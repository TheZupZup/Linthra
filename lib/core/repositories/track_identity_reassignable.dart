/// Optional capability for anything that keys durable per-track state on the
/// provider-namespaced [Track.uri] and can carry that state to a different uri.
///
/// It exists for exactly one situation: a **local file that moved**. The
/// catalog itself needs no help (the file is re-scanned at its new path and
/// the row is written there), but a local track's uri *is* its path, so every
/// store keyed on that uri (play counts, hearts, the "added on" date behind
/// Recently added) is suddenly pointing at a path nothing lives at. Without
/// this, dragging an album into a different folder quietly resets the listening
/// history the user built up for it.
///
/// Kept as a separate capability, in the same shape as `SourceCatalogReader`
/// and `IncrementalCatalogWriter`, so the many stores and test fakes that never
/// need it stay source-compatible: a caller checks
/// `store is TrackIdentityReassignable` and skips the ones that are not.
///
/// **Only ever called for a move the scan proved.** The identity rules live in
/// `LocalTrackIdentity` and are tag-based, never name-based, and refuse on any
/// ambiguity, so implementations can treat a call as authoritative and do not
/// second-guess it.
abstract interface class TrackIdentityReassignable {
  /// Moves whatever is stored under [fromUri] to [toUri].
  ///
  /// A no-op when nothing is stored under [fromUri], or when the two are equal.
  /// When [toUri] already carries state, the two are merged in whichever way
  /// loses nothing (counts add up, the later timestamp wins, a heart stays a
  /// heart). The implementation decides, because only it knows what its state
  /// means.
  ///
  /// Must never throw: a store that cannot re-key right now leaves its state
  /// alone rather than failing the scan that asked.
  Future<void> reassignTrack({
    required String fromUri,
    required String toUri,
  });
}
