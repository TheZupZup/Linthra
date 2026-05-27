import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/play_history.dart';
import 'package:linthra/data/repositories/shared_preferences_play_history_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('SharedPreferencesPlayHistoryStore', () {
    test('round-trips counts and last-played times', () async {
      const SharedPreferencesPlayHistoryStore store =
          SharedPreferencesPlayHistoryStore();
      final PlayHistory history = PlayHistory(
        stats: <String, TrackPlayStats>{
          'a': TrackPlayStats(playCount: 3, lastPlayedAt: DateTime(2024, 5, 1)),
          'b': TrackPlayStats(playCount: 1, lastPlayedAt: DateTime(2024, 5, 2)),
        },
      );

      await store.save(history);
      final PlayHistory loaded = await store.load();

      expect(loaded.playCountFor('a'), 3);
      expect(loaded.lastPlayedFor('a'), DateTime(2024, 5, 1));
      expect(loaded.playCountFor('b'), 1);
      expect(loaded.lastPlayedFor('b'), DateTime(2024, 5, 2));
    });

    test('returns empty for no stored value', () async {
      const SharedPreferencesPlayHistoryStore store =
          SharedPreferencesPlayHistoryStore();
      expect((await store.load()).stats, isEmpty);
    });

    test('a corrupt record reads as no history', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'play_history_v1': 'not json {',
      });
      const SharedPreferencesPlayHistoryStore store =
          SharedPreferencesPlayHistoryStore();
      expect((await store.load()).stats, isEmpty);
    });

    test('drops malformed entries (bad/zero count) without crashing', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'play_history_v1':
            '{"a":{"c":2,"t":1700000000000},"b":{"c":0,"t":1},"c":"nope"}',
      });
      const SharedPreferencesPlayHistoryStore store =
          SharedPreferencesPlayHistoryStore();
      final PlayHistory loaded = await store.load();
      expect(loaded.stats.keys, <String>['a']);
      expect(loaded.playCountFor('a'), 2);
    });

    test('the persisted document holds only ids/counts/times — no token',
        () async {
      // Even if a track carried a tokenized uri, play history stores only the
      // id, so the persisted JSON can never leak it.
      const String token = 'super-secret-token-1234567890';
      const SharedPreferencesPlayHistoryStore store =
          SharedPreferencesPlayHistoryStore();
      // The id is the only track field play history ever sees.
      await store.save(PlayHistory(
        stats: <String, TrackPlayStats>{
          'track-1': TrackPlayStats(
            playCount: 1,
            lastPlayedAt: DateTime(2024, 1, 1),
          ),
        },
      ));

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String raw = prefs.getString('play_history_v1') ?? '';
      expect(raw, contains('track-1'));
      expect(raw, isNot(contains(token)));
      expect(raw, isNot(contains('http')));
    });
  });
}
