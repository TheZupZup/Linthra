/// The local data group whose durable write failed.
///
/// These are fixed structural labels so callers can report a failure without
/// ever carrying the data that failed to persist.
enum LocalStoreArea {
  playlists,
  favorites,
  playHistory,
}

/// A durable local-store write that explicitly reported it did not happen.
///
/// `shared_preferences` returns `false` when a platform write fails (for
/// example, a full disk on Linux). Treating that as success makes the in-memory
/// copy look saved until the next launch reloads the older document.
class LocalStoreWriteException implements Exception {
  const LocalStoreWriteException(this.area);

  final LocalStoreArea area;

  @override
  String toString() => 'LocalStoreWriteException(${area.name})';
}
