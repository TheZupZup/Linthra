/// Durable storage for the set of track IDs that are available offline.
///
/// This is the *persistence seam* under [DownloadRepository]: it knows nothing
/// about download policy, connectivity, or the transient queued/downloading
/// states — only which tracks are fully cached on disk and survive a restart.
/// Splitting it out keeps the download lifecycle (policy) in one place while
/// letting the backing store swap freely (in-memory for tests, key/value in the
/// app, a SQLite/Drift table once real remote downloads track file paths and
/// byte progress).
abstract interface class DownloadStore {
  /// The track IDs currently cached for offline use.
  Future<Set<String>> loadDownloadedIds();

  /// Replaces the persisted set with [ids].
  Future<void> saveDownloadedIds(Set<String> ids);
}
