import '../models/track.dart';

/// Where a track stands in the offline-download lifecycle.
enum DownloadStatus { notDownloaded, queued, downloading, downloaded, failed }

/// Thrown by [DownloadRepository.requestDownload] when a download can't be
/// cached because the cache is at its limit and nothing safe is left to evict
/// (everything remaining is pinned or currently playing, or the track is larger
/// than the whole limit).
///
/// The [message] is friendly and secret-free by design — it never carries a
/// URL, token, or file path — so the UI can show it verbatim.
class CacheStorageException implements Exception {
  const CacheStorageException([
    this.message =
        'Not enough cache space. Free up space or raise the cache limit '
            'in Settings, then try again.',
  ]);

  final String message;

  @override
  String toString() => message;
}

/// Tracks which library items are available offline.
///
/// Downloads in Linthra are always *explicit and user-initiated* — never
/// automatic. Implementations must also honor the user's "Wi-Fi only" pref
/// (queueing rather than downloading over mobile data when set), so that
/// promise is enforced in one place rather than scattered through the UI.
///
/// [requestDownload] takes the whole [Track], not just an id, so the repository
/// can be *source-aware*: a remote (Jellyfin) track has its bytes fetched and
/// cached, while an on-device track — already local — is recorded as available
/// offline without any network fetch. The authenticated URL a remote fetch
/// needs is resolved on demand, at download time, and never stored on the track.
abstract interface class DownloadRepository {
  /// Emits whenever a track's download status changes.
  Stream<Map<String, DownloadStatus>> get statusStream;

  Future<DownloadStatus> statusFor(String trackId);

  /// Queues an explicit download for [track]. For remote tracks this is subject
  /// to the user's connectivity preferences; on-device tracks are recorded as
  /// already-available with no network fetch.
  ///
  /// To stay under the user's cache limit, a remote download may first evict
  /// least-recently-used, unpinned, not-currently-playing tracks. If even then
  /// there isn't room, it throws [CacheStorageException] and caches nothing.
  Future<void> requestDownload(Track track);

  /// Removes the offline copy of [trackId], deleting any cached file and
  /// freeing storage.
  Future<void> removeDownload(String trackId);

  /// Track IDs that are fully available offline.
  Future<List<String>> downloadedTrackIds();
}
