import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/data/repositories/in_memory_download_store.dart';
import 'package:linthra/data/repositories/in_memory_offline_file_store.dart';
import 'package:linthra/data/repositories/store_cached_track_locator.dart';

Track _jellyfin(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');

void main() {
  group('StoreCachedTrackLocator', () {
    late InMemoryDownloadStore store;
    late InMemoryOfflineFileStore files;

    setUp(() {
      store = InMemoryDownloadStore();
      files = InMemoryOfflineFileStore();
    });

    StoreCachedTrackLocator build() => StoreCachedTrackLocator(store, files);

    test('returns the cached path for a downloaded remote track', () async {
      final String fileName =
          await files.write('j1', const <int>[1, 2, 3], extension: 'mp3');
      await store.saveDownloads(<CachedTrack>[
        CachedTrack(trackId: 'j1', fileName: fileName),
      ]);

      final String? path = await build().cachedFilePath(_jellyfin('j1'));

      expect(path, '/offline_audio/j1.mp3');
    });

    test('returns null for a track that is not downloaded', () async {
      expect(await build().cachedFilePath(_jellyfin('nope')), isNull);
    });

    test('returns null for a track recorded without a cache file', () async {
      // An on-device track is recorded with no file name.
      await store.saveDownloads(const <CachedTrack>[CachedTrack(trackId: 'a')]);

      expect(
        await build().cachedFilePath(
          const Track(id: 'a', title: 'a', uri: 'file:///a.mp3'),
        ),
        isNull,
      );
    });

    test('returns null when the cache file is missing on disk', () async {
      // Metadata points at a file that the file store doesn't have.
      await store.saveDownloads(<CachedTrack>[
        const CachedTrack(trackId: 'j1', fileName: 'j1.mp3'),
      ]);

      expect(await build().cachedFilePath(_jellyfin('j1')), isNull);
    });
  });
}
