import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/data/repositories/in_memory_download_store.dart';
import 'package:linthra/data/repositories/in_memory_offline_file_store.dart';
import 'package:linthra/data/repositories/store_cached_track_locator.dart';

Track _jellyfin(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');
Track _plex(String id) => Track(id: id, title: id, uri: 'plex:$id');
Track _subsonic(String id) => Track(id: id, title: id, uri: 'subsonic:$id');

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

    test('returns the cached path for a downloaded Plex track', () async {
      // A Plex track is keyed by its stable ratingKey id like any other
      // provider — the locator is provider-agnostic.
      final String fileName =
          await files.write('101', const <int>[4, 5, 6], extension: 'flac');
      await store.saveDownloads(<CachedTrack>[
        CachedTrack(trackId: '101', fileName: fileName, sourceType: 'plex'),
      ]);

      final String? path = await build().cachedFilePath(_plex('101'));

      expect(path, '/offline_audio/101.flac');
    });

    test('returns null when a Plex cache file is missing, so playback streams',
        () async {
      // The metadata exists but the bytes are gone (reclaimed/removed): the
      // locator reports no path, so the offline-first resolver falls back to
      // streaming rather than opening a missing file.
      await store.saveDownloads(<CachedTrack>[
        const CachedTrack(
            trackId: '101', fileName: '101.flac', sourceType: 'plex'),
      ]);

      expect(await build().cachedFilePath(_plex('101')), isNull);
    });

    test('a Plex and a Jellyfin entry sharing an id resolve to their own files',
        () async {
      // Provider-aware matching: identical trackIds from different sources each
      // resolve to their own file, never the other's.
      await files.write('plex_101', const <int>[1], extension: 'mp3');
      await files.write('jellyfin_101', const <int>[2], extension: 'mp3');
      await store.saveDownloads(<CachedTrack>[
        const CachedTrack(
            trackId: '101', fileName: 'plex_101.mp3', sourceType: 'plex'),
        const CachedTrack(
            trackId: '101',
            fileName: 'jellyfin_101.mp3',
            sourceType: 'jellyfin'),
      ]);

      expect(await build().cachedFilePath(_plex('101')),
          '/offline_audio/plex_101.mp3');
      expect(await build().cachedFilePath(_jellyfin('101')),
          '/offline_audio/jellyfin_101.mp3');
    });

    test('a legacy entry without a recorded source still resolves by id',
        () async {
      // Back-compat: a cached file written before source tagging carries no
      // sourceType, so it falls back to an id-only match and keeps working.
      await files.write('legacy', const <int>[9], extension: 'mp3');
      await store.saveDownloads(<CachedTrack>[
        const CachedTrack(trackId: 'legacy', fileName: 'legacy.mp3'),
      ]);

      expect(await build().cachedFilePath(_jellyfin('legacy')),
          '/offline_audio/legacy.mp3');
    });

    test('a legacy untagged record is not served when the id is ambiguous',
        () async {
      // jellyfin:101 was cached pre-tagging (untagged). A Subsonic source now
      // also exposes id 101, so the untagged bytes can't be attributed — the
      // locator must serve neither copy from them (it streams instead).
      final String fileName =
          await files.write('legacy101', const <int>[9], extension: 'mp3');
      await store.saveDownloads(<CachedTrack>[
        CachedTrack(trackId: '101', fileName: fileName),
      ]);
      final StoreCachedTrackLocator locator = StoreCachedTrackLocator(
        store,
        files,
        catalogForLegacyMatch: () async =>
            <Track>[_jellyfin('101'), _subsonic('101')],
      );

      expect(await locator.cachedFilePath(_jellyfin('101')), isNull);
      expect(await locator.cachedFilePath(_subsonic('101')), isNull);
    });

    test('a legacy untagged record is served when the id is unambiguous',
        () async {
      // Only one provider exposes id 101, so the untagged bytes are safely its.
      final String fileName =
          await files.write('legacy101', const <int>[9], extension: 'mp3');
      await store.saveDownloads(<CachedTrack>[
        CachedTrack(trackId: '101', fileName: fileName),
      ]);
      final StoreCachedTrackLocator locator = StoreCachedTrackLocator(
        store,
        files,
        catalogForLegacyMatch: () async => <Track>[_jellyfin('101')],
      );

      expect(await locator.cachedFilePath(_jellyfin('101')),
          '/offline_audio/legacy101.mp3');
    });

    test(
        'a legacy untagged record is withheld when the sole owner is a '
        'different provider', () async {
      // The requested copy (plex:101) is no longer in the catalog (its source was
      // removed) but stays queued; the only owner of id 101 is now Jellyfin, so
      // the untagged file is Jellyfin's and must not play for the Plex copy.
      final String fileName =
          await files.write('legacy101', const <int>[9], extension: 'mp3');
      await store.saveDownloads(<CachedTrack>[
        CachedTrack(trackId: '101', fileName: fileName),
      ]);
      final StoreCachedTrackLocator locator = StoreCachedTrackLocator(
        store,
        files,
        catalogForLegacyMatch: () async => <Track>[_jellyfin('101')],
      );

      expect(await locator.cachedFilePath(_plex('101')), isNull);
    });
  });
}
