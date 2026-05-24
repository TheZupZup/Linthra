import '../../core/models/track.dart';
import '../../core/repositories/download_store.dart';
import '../../core/repositories/offline_file_store.dart';
import '../../core/services/cached_track_locator.dart';

/// The app's [CachedTrackLocator]: answers "is this track available offline?" by
/// reading the durable download metadata ([DownloadStore]) and confirming the
/// bytes are still on disk ([OfflineFileStore]).
///
/// Reading the stores directly — rather than the download repository's
/// in-memory state — keeps the playback read-path decoupled from download
/// *policy*: it sees exactly what has been persisted. A track with no cache
/// file (including any already-local on-device track) resolves to `null`, so
/// playback falls back to its normal source.
class StoreCachedTrackLocator implements CachedTrackLocator {
  const StoreCachedTrackLocator(this._store, this._files);

  final DownloadStore _store;
  final OfflineFileStore _files;

  @override
  Future<String?> cachedFilePath(Track track) async {
    String? fileName;
    for (final CachedTrack cached in await _store.loadDownloads()) {
      if (cached.trackId == track.id) {
        fileName = cached.fileName;
        break;
      }
    }
    if (fileName == null || fileName.isEmpty) return null;
    return _files.pathFor(fileName);
  }
}
