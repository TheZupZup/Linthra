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

    DefaultPlayHistoryRepository build({DateTime Function()? now}) {
      final DefaultPlayHistoryRepository repository =
          DefaultPlayHistoryRepository(store: store, now: now);
      addTearDown(repository.dispose);
      return repository;
    }

    test('records a completed play, incrementing the count', () async {
      final DefaultPlayHistoryRepository repository = build();

      await repository.recordCompletion(_t('a'));
      expect(repository.current.playCountFor('a'), 1);

      await repository.recordCompletion(_t('a'));
      expect(repository.current.playCountFor('a'), 2);
    });

    test('updates last-played time on completion', () async {
      DateTime clock = DateTime(2024, 1, 1, 9);
      final DefaultPlayHistoryRepository repository = build(now: () => clock);

      await repository.recordCompletion(_t('a'));
      expect(repository.current.lastPlayedFor('a'), DateTime(2024, 1, 1, 9));

      clock = DateTime(2024, 1, 1, 10);
      await repository.recordCompletion(_t('a'));
      expect(repository.current.lastPlayedFor('a'), DateTime(2024, 1, 1, 10));
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
      expect(repository.current.recentlyPlayedIds, <String>['c', 'b', 'a']);

      // Replaying 'a' moves it back to the front.
      await repository.recordCompletion(_t('a'));
      expect(repository.current.recentlyPlayedIds, <String>['a', 'c', 'b']);
    });

    test('most played orders by count', () async {
      final DefaultPlayHistoryRepository repository = build();
      await repository.recordCompletion(_t('a'));
      await repository.recordCompletion(_t('b'));
      await repository.recordCompletion(_t('b'));
      await repository.recordCompletion(_t('b'));
      await repository.recordCompletion(_t('c'));
      await repository.recordCompletion(_t('c'));
      expect(repository.current.mostPlayedIds, <String>['b', 'c', 'a']);
    });

    test('historyStream emits the initial history then every change', () async {
      final DefaultPlayHistoryRepository repository = build();
      final List<int> counts = <int>[];
      final sub = repository.historyStream
          .listen((PlayHistory h) => counts.add(h.playCountFor('a')));

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
      expect(second.current.playCountFor('a'), 2);
    });

    test('only the track id is recorded — never its uri', () async {
      const String token = 'secret-token-abc123';
      final DefaultPlayHistoryRepository repository = build();
      const Track tokenized =
          Track(id: 'a', title: 'A', uri: 'https://x/?t=$token');
      await repository.recordCompletion(tokenized);

      expect(repository.current.stats.containsKey('a'), isTrue);
      // The stats carry only count + time, never the uri/token.
      final TrackPlayStats stats = repository.current.stats['a']!;
      expect(stats.playCount, 1);
      expect(stats.toString(), isNot(contains(token)));
    });
  });
}
