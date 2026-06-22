/// Durable storage for when each catalog track was first added to the library.
///
/// Records a `trackUri -> firstSeen` map that powers the "Recently added" smart
/// mix. It's written by [RecordingMusicLibraryRepository] as a side effect of a
/// scan/sync (stamping newly-seen tracks with the time they first appeared),
/// and read by the smart-mix layer. Keyed by the provider-namespaced
/// [Track.uri] (e.g. `jellyfin:101`, `plex:101`, or a local path) so the same
/// server-side id from two providers can't share a timestamp. Kept as a separate
/// seam so the backing store swaps freely (in-memory for tests, key/value in the
/// app), mirroring [FavoritesStore].
///
/// Privacy: only non-secret, namespaced track uris and timestamps are stored
/// here — never a token or an authenticated URL. It never leaves the device.
abstract interface class LibraryAddedStore {
  Future<Map<String, DateTime>> load();
  Future<void> save(Map<String, DateTime> addedAt);
}
