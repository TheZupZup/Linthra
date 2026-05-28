import 'dart:async';

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
/// Security invariant: cache and temp file names are derived only from the
/// *non-secret* track id plus a local nonce. An access token or authenticated URL
/// must never appear in a file name, a path, or anything this store persists.
abstract interface class OfflineFileStore {
  /// Writes [bytes] for [trackId] into the offline directory and returns the
  /// file name (relative to that directory) they were stored under. The name is
  /// derived from [trackId] — plus [extension] when the source reported one —
  /// never from a token.
  Future<String> write(String trackId, List<int> bytes, {String? extension});

  /// Streams [chunks] into an app-managed temporary file and returns an opaque
  /// temp-file handle. The temp is not referenced by cache metadata until
  /// [commitTemp] succeeds. Call [deleteTemp] on failure/cancel.
  ///
  /// [onProgress] receives byte counts only — never URLs, paths, or tokens — and
  /// may be called several times as chunks are written.
  Future<OfflineTempFile> writeTemp(
    String trackId,
    Stream<List<int>> chunks, {
    String? extension,
    int? totalBytes,
    void Function(int received, int? total)? onProgress,
  });

  /// Atomically promotes [temp] into the final offline cache file for [trackId]
  /// and returns the final file name. After this succeeds, the temp handle must
  /// not be used again.
  Future<String> commitTemp(
    String trackId,
    OfflineTempFile temp, {
    String? extension,
  });

  /// Deletes [temp] if it still exists. Safe to call after partial writes or
  /// failed/cancelled downloads.
  Future<void> deleteTemp(OfflineTempFile temp);

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

/// Opaque handle for bytes staged by [OfflineFileStore.writeTemp].
class OfflineTempFile {
  const OfflineTempFile({required this.id, required this.sizeBytes});

  /// Store-specific identifier/path for the temp file. It is intentionally
  /// opaque to callers and is never persisted as cache metadata.
  final String id;

  /// Number of bytes successfully written to the temp file.
  final int sizeBytes;
}
