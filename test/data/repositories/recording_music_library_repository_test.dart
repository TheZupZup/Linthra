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
      // Keyed by the provider-namespaced uri, not the bare id.
      expect(added['jellyfin:a'], now);
      expect(added['jellyfin:b'], now);
      // The catalog write itself still went through to the delegate.
      expect((await repo.getAllTracks()).map((Track t) => t.id),
          containsAll(<String>['a', 'b']));
    });

    test('preserves the original time for tracks seen in a previous sync',
        () async {
      DateTime clock = DateTime(2024, 6, 1);
      final RecordingMusicLibraryRepository repo = build(now: () => clock);

      await sync(repo, <Track>[_t('a')]);
      final DateTime firstSeenA = (await addedStore.load())['jellyfin:a']!;

      // A later re-sync that still includes 'a' and adds 'b'.
      clock = DateTime(2024, 6, 10);
      await sync(repo, <Track>[_t('a'), _t('b')]);

      final Map<String, DateTime> added = await addedStore.load();
      // 'a' keeps its original first-seen time; only 'b' gets the new time.
      expect(added['jellyfin:a'], firstSeenA);
      expect(added['jellyfin:b'], DateTime(2024, 6, 10));
    });

    test('forgets the timestamp when a track is removed', () async {
      final RecordingMusicLibraryRepository repo =
          build(now: () => DateTime(2024, 6, 1));
      await sync(repo, <Track>[_t('a'), _t('b')]);

      // removeTracks is keyed by uri (the catalog's identity).
      await repo.removeTracks(<String>['jellyfin:a']);

      final Map<String, DateTime> added = await addedStore.load();
      expect(added.containsKey('jellyfin:a'), isFalse);
      expect(added.containsKey('jellyfin:b'), isTrue);
    });

    test('keys the timestamp store by the provider-namespaced uri', () async {
      final RecordingMusicLibraryRepository repo = build();
      await sync(repo, <Track>[_t('a')]);
      final Map<String, DateTime> added = await addedStore.load();
      // The credential-free uri (scheme:id) is the key — never the bare id, so
      // two providers' same-id tracks can't share a timestamp. (Track.uri is
      // guaranteed credential-free by the source mappers, tested there.)
      expect(added.keys, <String>['jellyfin:a']);
    });

    test(
        'removing a remote track before migration also clears its legacy id key',
        () async {
      // Pre-v2 store: an id-keyed entry that no sync has migrated yet.
      final DateTime legacy = DateTime(2023, 1, 1);
      await addedStore.save(<String, DateTime>{'101': legacy});

      final RecordingMusicLibraryRepository repo =
          build(now: () => DateTime(2024, 6, 10));
      // Remove by uri (the catalog key) before any stamp has migrated '101'.
      await repo.removeTracks(<String>['jellyfin:101']);
      expect((await addedStore.load()).containsKey('101'), isFalse);

      // A later re-sync now treats it as genuinely new, not the stale legacy time.
      await sync(repo, <Track>[_t('101')]); // uri: jellyfin:101
      expect((await addedStore.load())['jellyfin:101'], DateTime(2024, 6, 10));
    });

    test(
        'migrates a legacy id-keyed timestamp to the uri key, preserving the time',
        () async {
      // A store written by a pre-v2 build keyed entries by the bare id. The first
      // sync that sees the track again must adopt that timestamp under the uri
      // key, not reset it to "now".
      final DateTime legacy = DateTime(2023, 1, 1);
      await addedStore.save(<String, DateTime>{'a': legacy});

      final RecordingMusicLibraryRepository repo =
          build(now: () => DateTime(2024, 6, 10));
      await sync(repo, <Track>[_t('a')]);

      final Map<String, DateTime> added = await addedStore.load();
      expect(added['jellyfin:a'], legacy); // original time preserved
      expect(added.containsKey('a'), isFalse); // legacy key cleaned up
    });
  });
}
