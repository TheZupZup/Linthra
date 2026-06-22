import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/play_history.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/default_play_history_repository.dart';
import 'package:linthra/data/repositories/in_memory_play_history_store.dart';

Track _t(String id) => Track(id: id, title: 'Title $id', uri: 'jellyfin:$id');

void main() {
  group('DefaultPlayHistoryRepository', () {
    late InMemoryPlayHistoryStore store;

    setUp(() {
      store = InMemoryPlayHistoryStore();
    });

    DefaultPlayHistoryRepository build({
      DateTime Function()? now,
      Future<List<Track>> Function()? catalogForMigration,
    }) {
      final DefaultPlayHistoryRepository repository =
          DefaultPlayHistoryRepository(
        store: store,
        now: now,
        catalogForMigration: catalogForMigration,
      );
      addTearDown(repository.dispose);
      return repository;
    }

    test('records a completed play, incrementing the count', () async {
      final DefaultPlayHistoryRepository repository = build();

      await repository.recordCompletion(_t('a'));
      expect(repository.current.playCountFor('jellyfin:a'), 1);

      await repository.recordCompletion(_t('a'));
      expect(repository.current.playCountFor('jellyfin:a'), 2);
    });

    test('updates last-played time on completion', () async {
      DateTime clock = DateTime(2024, 1, 1, 9);
      final DefaultPlayHistoryRepository repository = build(now: () => clock);

      await repository.recordCompletion(_t('a'));
      expect(repository.current.lastPlayedFor('jellyfin:a'),
          DateTime(2024, 1, 1, 9));

      clock = DateTime(2024, 1, 1, 10);
      await repository.recordCompletion(_t('a'));
      expect(repository.current.lastPlayedFor('jellyfin:a'),
          DateTime(2024, 1, 1, 10));
    });

    test('recently played reflects completion order, most-recent first',
        () async {
      DateTime clock = DateTime(2024, 1, 1, 0);
      DateTime tick() {
        clock = clock.add(const Duration(minutes: 1));
        return clock;
      }

      final DefaultPlayHistoryRepository repository = build(now: tick);

      await repository.recordCompletion(_t('a'));
      await repository.recordCompletion(_t('b'));
      await repository.recordCompletion(_t('c'));
      expect(repository.current.recentlyPlayedKeys,
          <String>['jellyfin:c', 'jellyfin:b', 'jellyfin:a']);

      // Replaying 'a' moves it back to the front.
      await repository.recordCompletion(_t('a'));
      expect(repository.current.recentlyPlayedKeys,
          <String>['jellyfin:a', 'jellyfin:c', 'jellyfin:b']);
    });

    test('most played orders by count', () async {
      final DefaultPlayHistoryRepository repository = build();
      await repository.recordCompletion(_t('a'));
      await repository.recordCompletion(_t('b'));
      await repository.recordCompletion(_t('b'));
      await repository.recordCompletion(_t('b'));
      await repository.recordCompletion(_t('c'));
      await repository.recordCompletion(_t('c'));
      expect(repository.current.mostPlayedKeys,
          <String>['jellyfin:b', 'jellyfin:c', 'jellyfin:a']);
    });

    test('historyStream emits the initial history then every change', () async {
      final DefaultPlayHistoryRepository repository = build();
      final List<int> counts = <int>[];
      final sub = repository.historyStream
          .listen((PlayHistory h) => counts.add(h.playCountFor('jellyfin:a')));

      await Future<void>.delayed(Duration.zero); // initial (empty) emission
      await repository.recordCompletion(_t('a'));
      await repository.recordCompletion(_t('a'));
      await Future<void>.delayed(Duration.zero);

      expect(counts, containsAllInOrder(<int>[0, 1, 2]));
      await sub.cancel();
    });

    test('persists through the store across instances', () async {
      final DefaultPlayHistoryRepository first = build();
      await first.recordCompletion(_t('a'));
      await first.recordCompletion(_t('a'));

      // A fresh repository over the same store sees the persisted count.
      final DefaultPlayHistoryRepository second = build();
      // Touch the stream to force a load.
      await second.historyStream.first;
      expect(second.current.playCountFor('jellyfin:a'), 2);
    });

    test('records the provider-namespaced uri, not the bare id', () async {
      // The stored key is the uri (the catalog's identity), so a same-id track
      // from another provider keeps its own count — and the bare id is never the
      // key, so it never collides.
      final DefaultPlayHistoryRepository repository = build();
      await repository.recordCompletion(_t('a'));

      expect(repository.current.stats.containsKey('jellyfin:a'), isTrue);
      expect(repository.current.stats.containsKey('a'), isFalse);
    });

    test('a play of one provider never marks a same-id sibling played',
        () async {
      // jellyfin:101 and subsonic:101 share the bare id 101 but are different
      // tracks; completing one must not touch the other.
      final DefaultPlayHistoryRepository repository = build();
      const Track jelly = Track(id: '101', title: 'Alpha', uri: 'jellyfin:101');
      const Track sub = Track(id: '101', title: 'Beta', uri: 'subsonic:101');

      await repository.recordCompletion(jelly);

      expect(repository.current.hasPlayed('jellyfin:101'), isTrue);
      expect(repository.current.hasPlayed('subsonic:101'), isFalse);
      expect(repository.current.playCountFor('subsonic:101'), 0);
      expect(repository.current.playCountFor(sub.uri), 0);
    });

    group('legacy bare-id migration', () {
      test('re-keys an unambiguous legacy bare-id count onto its uri',
          () async {
        store = InMemoryPlayHistoryStore(
          PlayHistory(stats: <String, TrackPlayStats>{
            '101': TrackPlayStats(
                playCount: 3, lastPlayedAt: DateTime(2024, 1, 1)),
          }),
        );
        // The catalog exposes id 101 under a single provider, so it's safe to
        // attribute the legacy count to that uri.
        final DefaultPlayHistoryRepository repository = build(
          catalogForMigration: () async => const <Track>[
            Track(id: '101', title: 'Alpha', uri: 'jellyfin:101'),
          ],
        );

        await repository.historyStream.first; // triggers the load + migration

        expect(repository.current.playCountFor('jellyfin:101'), 3);
        expect(repository.current.stats.containsKey('101'), isFalse);
        // Persisted, so the next launch reads the migrated form.
        expect((await store.load()).stats.containsKey('jellyfin:101'), isTrue);
      });

      test('folds a legacy count into an existing uri count', () async {
        store = InMemoryPlayHistoryStore(
          PlayHistory(stats: <String, TrackPlayStats>{
            '101': TrackPlayStats(
                playCount: 2, lastPlayedAt: DateTime(2024, 1, 1)),
            'jellyfin:101': TrackPlayStats(
                playCount: 5, lastPlayedAt: DateTime(2024, 1, 3)),
          }),
        );
        final DefaultPlayHistoryRepository repository = build(
          catalogForMigration: () async => const <Track>[
            Track(id: '101', title: 'Alpha', uri: 'jellyfin:101'),
          ],
        );

        await repository.historyStream.first;

        // Counts summed (2 + 5) and the later last-played kept.
        expect(repository.current.playCountFor('jellyfin:101'), 7);
        expect(repository.current.lastPlayedFor('jellyfin:101'),
            DateTime(2024, 1, 3));
        expect(repository.current.stats.containsKey('101'), isFalse);
      });

      test('leaves an ambiguous legacy bare id untouched (never guesses)',
          () async {
        store = InMemoryPlayHistoryStore(
          PlayHistory(stats: <String, TrackPlayStats>{
            '101': TrackPlayStats(
                playCount: 4, lastPlayedAt: DateTime(2024, 1, 1)),
          }),
        );
        // Two providers both expose id 101: the legacy count can't be safely
        // attributed to either, so it stays a bare key (inert under uri reads).
        final DefaultPlayHistoryRepository repository = build(
          catalogForMigration: () async => const <Track>[
            Track(id: '101', title: 'Alpha', uri: 'jellyfin:101'),
            Track(id: '101', title: 'Beta', uri: 'subsonic:101'),
          ],
        );

        await repository.historyStream.first;

        expect(repository.current.hasPlayed('jellyfin:101'), isFalse);
        expect(repository.current.hasPlayed('subsonic:101'), isFalse);
        // Preserved, not dropped.
        expect(repository.current.stats.containsKey('101'), isTrue);
        expect(repository.current.playCountFor('101'), 4);
      });

      test('a local path key (id == uri) is left as-is', () async {
        store = InMemoryPlayHistoryStore(
          PlayHistory(stats: <String, TrackPlayStats>{
            '/music/song.mp3': TrackPlayStats(
                playCount: 1, lastPlayedAt: DateTime(2024, 1, 1)),
          }),
        );
        final DefaultPlayHistoryRepository repository = build(
          catalogForMigration: () async => const <Track>[
            Track(id: '/music/song.mp3', title: 'Song', uri: '/music/song.mp3'),
          ],
        );

        await repository.historyStream.first;

        expect(repository.current.playCountFor('/music/song.mp3'), 1);
      });
    });
  });
}
