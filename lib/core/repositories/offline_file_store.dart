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
  /// Writes [bytes] for [trackId] into the offline directory and returns the
  /// file name (relative to that directory) they were stored under. The name is
  /// derived from [trackId] — plus [extension] when the source reported one —
  /// never from a token.
  Future<String> write(String trackId, List<int> bytes, {String? extension});

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
}
