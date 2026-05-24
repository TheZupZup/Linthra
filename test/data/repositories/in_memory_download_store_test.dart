import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/data/repositories/in_memory_download_store.dart';

void main() {
  group('InMemoryDownloadStore', () {
    test('starts empty', () async {
      expect(await InMemoryDownloadStore().loadDownloads(), isEmpty);
    });

    test('seeds from initial downloads', () async {
      final store = InMemoryDownloadStore(
        initialDownloads: const <CachedTrack>[
          CachedTrack(trackId: 'a', fileName: 'a.mp3'),
          CachedTrack(trackId: 'b'),
        ],
      );
      expect(await store.loadDownloads(), <CachedTrack>[
        const CachedTrack(trackId: 'a', fileName: 'a.mp3'),
        const CachedTrack(trackId: 'b'),
      ]);
    });

    test('save replaces the stored set', () async {
      final store = InMemoryDownloadStore(
        initialDownloads: const <CachedTrack>[CachedTrack(trackId: 'a')],
      );
      await store.saveDownloads(const <CachedTrack>[
        CachedTrack(trackId: 'b', fileName: 'b.flac'),
        CachedTrack(trackId: 'c'),
      ]);
      expect(
        (await store.loadDownloads()).map((c) => c.trackId).toList(),
        <String>['b', 'c'],
      );
    });

    test('load returns a list that callers cannot use to mutate the store',
        () async {
      final store = InMemoryDownloadStore(
        initialDownloads: const <CachedTrack>[CachedTrack(trackId: 'a')],
      );
      (await store.loadDownloads()).add(const CachedTrack(trackId: 'rogue'));
      expect(
        (await store.loadDownloads()).map((c) => c.trackId).toList(),
        <String>['a'],
      );
    });
  });
}
