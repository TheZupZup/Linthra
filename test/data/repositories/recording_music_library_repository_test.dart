import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_library_added_store.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/recording_music_library_repository.dart';

Track _t(String id) => Track(id: id, title: 'Title $id', uri: 'jellyfin:$id');

void main() {
  group('RecordingMusicLibraryRepository', () {
    late InMemoryMusicLibraryRepository delegate;
    late InMemoryLibraryAddedStore addedStore;

    setUp(() {
      delegate = InMemoryMusicLibraryRepository();
      addedStore = InMemoryLibraryAddedStore();
    });

    RecordingMusicLibraryRepository build({DateTime Function()? now}) {
      return RecordingMusicLibraryRepository(
        delegate: delegate,
        addedStore: addedStore,
        now: now,
      );
    }

    Future<void> sync(
      RecordingMusicLibraryRepository repo,
      List<Track> tracks, {
      String sourceId = 'jellyfin',
    }) {
      return repo.upsertCatalog(
        sourceId: sourceId,
        tracks: tracks,
        albums: const <Album>[],
        artists: const <Artist>[],
      );
    }

    test('stamps newly-seen tracks with the current time on sync', () async {
      final DateTime now = DateTime(2024, 6, 1, 12);
      final RecordingMusicLibraryRepository repo = build(now: () => now);

      await sync(repo, <Track>[_t('a'), _t('b')]);

      final Map<String, DateTime> added = await addedStore.load();
      expect(added['a'], now);
      expect(added['b'], now);
      // The catalog write itself still went through to the delegate.
      expect((await repo.getAllTracks()).map((Track t) => t.id),
          containsAll(<String>['a', 'b']));
    });

    test('preserves the original time for tracks seen in a previous sync',
        () async {
      DateTime clock = DateTime(2024, 6, 1);
      final RecordingMusicLibraryRepository repo = build(now: () => clock);

      await sync(repo, <Track>[_t('a')]);
      final DateTime firstSeenA = (await addedStore.load())['a']!;

      // A later re-sync that still includes 'a' and adds 'b'.
      clock = DateTime(2024, 6, 10);
      await sync(repo, <Track>[_t('a'), _t('b')]);

      final Map<String, DateTime> added = await addedStore.load();
      // 'a' keeps its original first-seen time; only 'b' gets the new time.
      expect(added['a'], firstSeenA);
      expect(added['b'], DateTime(2024, 6, 10));
    });

    test('forgets the timestamp when a track is removed', () async {
      final RecordingMusicLibraryRepository repo =
          build(now: () => DateTime(2024, 6, 1));
      await sync(repo, <Track>[_t('a'), _t('b')]);

      await repo.removeTracks(<String>['a']);

      final Map<String, DateTime> added = await addedStore.load();
      expect(added.containsKey('a'), isFalse);
      expect(added.containsKey('b'), isTrue);
    });

    test('the timestamp store never holds a track uri', () async {
      final RecordingMusicLibraryRepository repo = build();
      await sync(repo, const <Track>[
        Track(id: 'a', title: 'A', uri: 'https://server/stream?token=secret'),
      ]);
      final Map<String, DateTime> added = await addedStore.load();
      expect(added.keys, <String>['a']);
      expect(added.toString(), isNot(contains('secret')));
    });
  });
}
