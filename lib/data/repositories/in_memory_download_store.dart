import '../../core/repositories/download_store.dart';

/// A non-persistent [DownloadStore] for development and tests.
///
/// Keeps the cached-track references in a plain map keyed by track id, so
/// they're forgotten when the instance is dropped. Default binding (mirroring
/// the other in-memory repositories); the running app swaps in the
/// `shared_preferences` implementation.
class InMemoryDownloadStore implements DownloadStore {
  InMemoryDownloadStore({List<CachedTrack>? initialDownloads})
      : _downloads = <String, CachedTrack>{
          for (final CachedTrack cached
              in initialDownloads ?? const <CachedTrack>[])
            cached.trackId: cached,
        };

  final Map<String, CachedTrack> _downloads;

  @override
  Future<List<CachedTrack>> loadDownloads() async => _downloads.values.toList();

  @override
  Future<void> saveDownloads(List<CachedTrack> downloads) async {
    _downloads
      ..clear()
      ..addEntries(
        downloads.map((c) => MapEntry<String, CachedTrack>(c.trackId, c)),
      );
  }
}
