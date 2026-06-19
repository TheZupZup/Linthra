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
    final String? scheme = _schemeOf(track.uri);
    String? fileName;
    for (final CachedTrack cached in await _store.loadDownloads()) {
      if (cached.trackId != track.id) continue;
      // Provider-aware: an entry matches only when its recorded source scheme
      // agrees, so a Plex `101` never resolves to a Subsonic `101`'s file. A
      // legacy entry written before source tagging (sourceType == null) falls
      // back to an id-only match — there is at most one such untagged file, so
      // it still resolves and existing cached tracks keep working.
      if (cached.sourceType != null && cached.sourceType != scheme) continue;
      fileName = cached.fileName;
      break;
    }
    if (fileName == null || fileName.isEmpty) return null;
    return _files.pathFor(fileName);
  }

  /// The non-secret URI scheme of [uri] (`jellyfin`, `subsonic`, `plex`, `file`,
  /// …), or `null` for a bare path — derived exactly as the repository records
  /// [CachedTrack.sourceType], so the two always agree.
  static String? _schemeOf(String uri) {
    final int colon = uri.indexOf(':');
    if (colon <= 0) return null;
    final String scheme = uri.substring(0, colon).toLowerCase();
    return scheme.isEmpty ? null : scheme;
  }
}
