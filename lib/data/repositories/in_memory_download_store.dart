import '../../core/repositories/download_store.dart';

/// A non-persistent [DownloadStore] for development and tests.
///
/// Keeps the cached-track references in a plain list, so they're forgotten when
/// the instance is dropped. Default binding (mirroring the other in-memory
/// repositories); the running app swaps in the `shared_preferences`
/// implementation. A list — not a map keyed by track id — so two entries that
/// share a catalog id but come from different providers (a Plex `101` and a
/// Subsonic `101`) both persist, exactly as the `shared_preferences` store keeps
/// them; the cache's provider-aware identity lives one layer up.
class InMemoryDownloadStore implements DownloadStore {
  InMemoryDownloadStore({List<CachedTrack>? initialDownloads})
      : _downloads = <CachedTrack>[...?initialDownloads];

  final List<CachedTrack> _downloads;

  @override
  Future<List<CachedTrack>> loadDownloads() async => _downloads.toList();

  @override
  Future<void> saveDownloads(List<CachedTrack> downloads) async {
    _downloads
      ..clear()
      ..addAll(downloads);
  }
}
