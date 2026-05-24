/// A reference to a single offline-cached track: which track it is and the file
/// that holds its downloaded bytes (when there is one).
///
/// Security invariant: this is *persisted* metadata, so it must never carry a
/// secret. [trackId] is the non-secret catalog id, and [fileName] is derived
/// from it — never from an access token or an authenticated URL. Do not add the
/// streaming/download URL, a Jellyfin token, or any credential to this record.
class CachedTrack {
  const CachedTrack({required this.trackId, this.fileName});

  /// The catalog id of the cached track.
  final String trackId;

  /// The cache file holding the downloaded bytes, relative to the offline
  /// directory — or `null` for an on-device track that is already local and so
  /// has no managed copy of its own.
  final String? fileName;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'trackId': trackId,
        if (fileName != null && fileName!.isNotEmpty) 'fileName': fileName,
      };

  /// Rebuilds a record from [toJson] output, or returns `null` when the track
  /// id is missing (a corrupt entry), so one bad record can't break loading.
  static CachedTrack? fromJson(Map<String, dynamic> json) {
    final String? trackId = json['trackId'] as String?;
    if (trackId == null || trackId.isEmpty) return null;
    final String? fileName = json['fileName'] as String?;
    return CachedTrack(
      trackId: trackId,
      fileName: (fileName != null && fileName.isNotEmpty) ? fileName : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedTrack &&
          other.trackId == trackId &&
          other.fileName == fileName);

  @override
  int get hashCode => Object.hash(trackId, fileName);
}

/// Durable storage for the tracks that are available offline.
///
/// This is the *persistence seam* under [DownloadRepository]: it knows nothing
/// about download policy, connectivity, or the transient queued/downloading
/// states — only which tracks are cached and, for the ones with a downloaded
/// copy, the file that holds the bytes. Splitting it out keeps the download
/// lifecycle (policy) in one place while letting the backing store swap freely
/// (in-memory for tests, key/value in the app, a SQLite/Drift table once
/// downloads also track byte progress).
abstract interface class DownloadStore {
  /// The tracks currently cached for offline use.
  Future<List<CachedTrack>> loadDownloads();

  /// Replaces the persisted set with [downloads].
  Future<void> saveDownloads(List<CachedTrack> downloads);
}
