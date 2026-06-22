import '../models/download_progress.dart';
import '../models/track.dart';

/// Where a track stands in the offline-download lifecycle.
enum DownloadStatus { notDownloaded, queued, downloading, downloaded, failed }

/// The result of a [DownloadRepository.requestDownload] call, so the UI can tell
/// the user *why* a download didn't start instead of failing silently.
enum DownloadRequestOutcome {
  /// The download started, was already in progress/finished, or (for an
  /// on-device track) was recorded immediately.
  started,

  /// Held back by the network policy: the device is on mobile data and the user
  /// hasn't allowed it (or the connection type is unknown). The track is queued
  /// and starts on Wi-Fi, or once the user allows mobile data.
  waitingForWifi,

  /// Held back because the device is offline. The track is queued and starts
  /// when a connection returns.
  waitingForConnection,
}

/// A friendly, secret-free line for an outcome that didn't start, or `null` when
/// the download started (so callers stay quiet on success). Never carries a URL,
/// token, or path, so the UI can show it verbatim.
extension DownloadRequestOutcomeMessage on DownloadRequestOutcome {
  String? get blockedMessage {
    switch (this) {
      case DownloadRequestOutcome.started:
        return null;
      case DownloadRequestOutcome.waitingForWifi:
        return 'Downloads are limited to Wi-Fi. Turn on "Allow mobile data" in '
            'Settings to download over mobile data.';
      case DownloadRequestOutcome.waitingForConnection:
        return "You're offline. This download will start automatically when "
            "you're back online.";
    }
  }
}

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
/// automatic. Implementations must also honor the user's mobile-data preference
/// (queueing rather than downloading over mobile data unless the user allowed
/// it), so that promise is enforced in one place rather than scattered through
/// the UI.
///
/// [requestDownload] takes the whole [Track], not just an id, so the repository
/// can be *source-aware*: a remote (Jellyfin) track has its bytes fetched and
/// cached, while an on-device track — already local — is recorded as available
/// offline without any network fetch. The authenticated URL a remote fetch
/// needs is resolved on demand, at download time, and never stored on the track.
abstract interface class DownloadRepository {
  /// Emits the download status of every tracked copy whenever one changes, keyed
  /// by the provider-aware cache key (`CachedTrack.cacheKeyForTrack`) so two
  /// providers' same-id copies never share a status. The UI's per-row status
  /// joins on that key.
  Stream<Map<String, DownloadStatus>> get statusStream;

  /// The status of the track with catalog id [trackId] — a plain-id convenience
  /// (the catalog's primary key makes ids unique there). The app's per-row status
  /// instead watches [statusStream], which is keyed provider-aware; the mutating
  /// calls below take the whole [Track], so they act on one provider's copy.
  Future<DownloadStatus> statusFor(String trackId);

  /// Emits per-track byte progress for in-flight downloads, keyed by the
  /// provider-aware cache key (`CachedTrack.cacheKeyForTrack`) — so two providers'
  /// same-id copies never share a progress ring. An entry appears while a track
  /// is downloading and is removed once it finishes, fails, or is canceled.
  /// Best-effort: a track whose server didn't report a content length has a null
  /// total ([DownloadProgress.fraction] is `null`), so the UI shows an
  /// indeterminate spinner rather than a bar.
  Stream<Map<String, DownloadProgress>> get progressStream;

  /// Queues an explicit download for [track]. For remote tracks this is subject
  /// to the user's connectivity preferences; on-device tracks are recorded as
  /// already-available with no network fetch.
  ///
  /// To stay under the user's cache limit, a remote download may first evict
  /// least-recently-used, unpinned, not-currently-playing tracks. If even then
  /// there isn't room, it throws [CacheStorageException] and caches nothing.
  ///
  /// Returns a [DownloadRequestOutcome] so the caller can tell the user when a
  /// download was queued by the network policy (mobile data not allowed, or
  /// offline) rather than started.
  Future<DownloadRequestOutcome> requestDownload(Track track);

  /// Removes the offline copy of [track], deleting any cached file and freeing
  /// storage. Takes the whole [Track] so removal is *provider-aware*: a Plex
  /// track and a Subsonic track that happen to share a catalog id never shadow
  /// or remove each other's cached copy.
  Future<void> removeDownload(Track track);

  /// The provider-aware cache keys (`CachedTrack.cacheKeyForTrack`) of every
  /// track fully available offline — keys, not bare ids, so two providers'
  /// same-id copies stay distinct and only the copy actually downloaded is
  /// listed. Join against a catalog [Track] with `CachedTrack.cacheKeyForTrack`.
  Future<List<String>> downloadedTrackKeys();
}
