/// Durable storage for when each catalog track was first added to the library.
///
/// Records a `trackId -> firstSeen` map that powers the "Recently added" smart
/// mix. It's written by [RecordingMusicLibraryRepository] as a side effect of a
/// scan/sync (stamping newly-seen track ids with the time they first appeared),
/// and read by the smart-mix layer. Kept as a separate seam so the backing
/// store swaps freely (in-memory for tests, key/value in the app), mirroring
/// [FavoritesStore].
///
/// Privacy: only non-secret track ids and timestamps are stored here — never a
/// uri, token, or authenticated URL. It never leaves the device.
abstract interface class LibraryAddedStore {
  Future<Map<String, DateTime>> load();
  Future<void> save(Map<String, DateTime> addedAt);
}
