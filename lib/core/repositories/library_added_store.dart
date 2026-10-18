import '../models/track.dart';

/// Durable storage for when each catalog track was first added to the library.
///
/// Records a `trackUri -> firstSeen` map that powers the "Recently added" smart
/// mix and the Songs list's "Date added" orders. It's written by
/// [RecordingMusicLibraryRepository] as a side effect of a scan/sync (stamping
/// newly-seen tracks with the time they first appeared), and read by the
/// smart-mix layer and the Library. Keyed by the provider-namespaced
/// [Track.uri] (e.g. `jellyfin:101`, `plex:101`, or a local path) so the same
/// server-side id from two providers can't share a timestamp. Kept as a separate
/// seam so the backing store swaps freely (in-memory for tests, key/value in the
/// app), mirroring [FavoritesStore].
///
/// Privacy: only non-secret, namespaced track uris and timestamps are stored
/// here — never a token or an authenticated URL. It never leaves the device.
abstract interface class LibraryAddedStore {
  Future<Map<String, DateTime>> load();

  /// Throws `LocalStoreWriteException` when the platform did not save it.
  Future<void> save(Map<String, DateTime> addedAt);
}

/// When [track] first entered the library according to [addedAt] (a
/// [LibraryAddedStore.load] result), or null when it has no recorded time.
///
/// Reads the [Track.uri] key the store is written under. Falls back to the
/// legacy bare-`id` key for a remote track whose timestamp predates the
/// uri-keyed store and hasn't been migrated yet: the first post-upgrade sync
/// migrates it in place, but a read can run before that.
DateTime? firstSeenAt(Track track, Map<String, DateTime> addedAt) {
  final DateTime? byUri = addedAt[track.uri];
  if (byUri != null) return byUri;
  if (track.uri != track.id) return addedAt[track.id];
  return null;
}
