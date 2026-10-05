/// Stores and retrieves the actual bytes of offline-cached tracks in an
/// app-controlled directory.
///
/// This is the filesystem seam under the offline cache: it knows where cached
/// audio lives on disk and how to read, write, and delete it, but nothing about
/// download policy, status, or which source a track came from. Splitting it out
/// keeps [DownloadStore] focused on the durable trackId→file metadata and lets
/// the byte storage be faked in tests (an in-memory map) instead of touching a
/// real filesystem or `path_provider`.
///
/// Security invariant: a cache file name is derived only from the *non-secret*
/// track id. An access token or authenticated URL must never appear in a file
/// name, a path, or anything this store persists.
abstract interface class OfflineFileStore {
  /// Starts a cache file for [trackId], to be filled a chunk at a time as a
  /// download arrives, so the download never sits in memory whole (#745).
  ///
  /// Until it is published, the draft is a temp file of its own in the
  /// offline directory that nothing reads, counts or serves, so two drafts of
  /// the same track (a download and a pre-cache) never share one. A draft
  /// left behind by a crash is cleared like any other temp file
  /// ([removeAbandoned]).
  Future<OfflineFileDraft> createDraft(String trackId);

  /// The absolute path of a previously stored [fileName], or `null` when no
  /// such file exists (e.g. the OS reclaimed it), so playback can fall back to
  /// streaming rather than open a missing file.
  Future<String?> pathFor(String fileName);

  /// The size in bytes of [fileName] on disk, or `null` when it no longer
  /// exists — used to total cache usage and to detect (and prune) metadata
  /// pointing at a file the OS reclaimed.
  Future<int?> sizeFor(String fileName);

  /// Deletes the cache file [fileName] if it exists; a no-op when it doesn't.
  Future<void> delete(String fileName);

  /// Deletes what an earlier run left in the offline directory that no cache
  /// record accounts for: the temp file of a write cut off mid-way, and, unless
  /// [temporaryOnly], a finished file not named in [referenced] (a download
  /// whose record was never saved). Nothing else ever counts, clears or evicts
  /// those, so without this they stay on disk for good (#747).
  ///
  /// Runs at most once per store, and only ever takes files untouched since
  /// before the store was created, so it can never take a file this run is
  /// writing.
  /// Best-effort: a file it can't remove is left as it is, and it never throws.
  Future<void> removeAbandoned(
    Set<String> referenced, {
    bool temporaryOnly = false,
  });
}

/// A cache file being written (see [OfflineFileStore.createDraft]).
abstract interface class OfflineFileDraft {
  /// How many bytes have been added so far.
  int get length;

  /// Appends [chunk]. Completes once it is written, so a fast server waits for
  /// the disk instead of piling up in memory.
  Future<void> add(List<int> chunk);

  /// Moves the finished draft into place as the track's cache file and returns
  /// its file name (relative to the offline directory). The name is derived
  /// from the draft's track id (plus [extension] when the source reported
  /// one), never from a token. The move is atomic, so the playback locator
  /// only ever sees the whole file or none.
  ///
  /// An empty draft (an interrupted fetch can end with zero bytes) is refused,
  /// since a 0-byte file would read as cached. A failed publish discards the
  /// draft.
  Future<String> publish({String? extension});

  /// Deletes the draft. A no-op once it is published or discarded, so it is
  /// safe in a `finally`. Never throws.
  Future<void> discard();
}
