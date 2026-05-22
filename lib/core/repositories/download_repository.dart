/// Where a track stands in the offline-download lifecycle.
enum DownloadStatus { notDownloaded, queued, downloading, downloaded, failed }

/// Tracks which library items are available offline.
///
/// Downloads in Sonara are always *explicit and user-initiated* — never
/// automatic. Implementations must also honor the user's "Wi-Fi only" pref
/// (queueing rather than downloading over mobile data when set), so that
/// promise is enforced in one place rather than scattered through the UI.
abstract interface class DownloadRepository {
  /// Emits whenever a track's download status changes.
  Stream<Map<String, DownloadStatus>> get statusStream;

  Future<DownloadStatus> statusFor(String trackId);

  /// Queues an explicit download for [trackId]. Subject to the user's
  /// connectivity preferences.
  Future<void> requestDownload(String trackId);

  /// Removes the local copy of [trackId], freeing storage.
  Future<void> removeDownload(String trackId);

  /// Track IDs that are fully available offline.
  Future<List<String>> downloadedTrackIds();
}
