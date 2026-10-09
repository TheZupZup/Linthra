import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/play_history.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/song_origins.dart';
import 'package:linthra/data/repositories/default_play_history_repository.dart';
import 'package:linthra/data/repositories/in_memory_play_history_store.dart';

import '../../support/fake_song_origins.dart';

/// #795: plays of `subsonic:48211` on two servers are two songs' plays.

const Track _song = Track(id: '48211', title: 'Song', uri: 'subsonic:48211');
const Track _jelly = Track(id: '6f1c', title: 'Jelly', uri: 'jellyfin:6f1c');
const Track _local =
    Track(id: '/music/a.flac', title: 'Local', uri: '/music/a.flac');

void main() {
  late FakeSongOrigins origins;
  late InMemoryPlayHistoryStore store;
  final DateTime t0 = DateTime(2026, 10, 1, 12);
  late DateTime clock;

  setUp(() {
    origins = FakeSongOrigins(
      signedIn: <String, String?>{'subsonic:': 'server-a'},
      legacy: <String, String>{'subsonic:': 'server-a'},
    );
    addTearDown(origins.close);
    store = InMemoryPlayHistoryStore();
    clock = t0;
  });

  DefaultPlayHistoryRepository repository() {
    final DefaultPlayHistoryRepository repo = DefaultPlayHistoryRepository(
      store: store,
      origins: origins,
      now: () => clock = clock.add(const Duration(minutes: 1)),
    );
    addTearDown(repo.dispose);
    return repo;
  }

  test('plays on two servers count apart, and each server sees its own',
      () async {
    final DefaultPlayHistoryRepository repo = repository();
    await repo.recordCompletion(_song);
    await repo.recordCompletion(_song);
    await repo.recordCompletion(_jelly);

    origins.signIn('subsonic:', 'server-b');
    await pumpEventQueue();
    // B's own song 48211 has never been played here.
    expect(repo.current.playCountFor('subsonic:48211'), 0);
    expect(repo.current.hasPlayed('subsonic:48211'), isFalse);
    expect(repo.current.playCountFor('jellyfin:6f1c'), 1);
    await repo.recordCompletion(_song);
    expect(repo.current.playCountFor('subsonic:48211'), 1);

    // Back on A, after a restart: A's count is A's alone.
    origins.signIn('subsonic:', 'server-a');
    final DefaultPlayHistoryRepository restarted = repository();
    final PlayHistory onA = await restarted.historyStream.first;
    expect(onA.playCountFor('subsonic:48211'), 2);
    expect(onA.mostPlayedKeys, <String>['subsonic:48211', 'jellyfin:6f1c']);
  });

  test('the stream re-emits when the server changes', () async {
    final DefaultPlayHistoryRepository repo = repository();
    await repo.recordCompletion(_song);
    final List<int> counts = <int>[];
    final sub = repo.historyStream.listen(
      (PlayHistory h) => counts.add(h.playCountFor('subsonic:48211')),
    );
    addTearDown(sub.cancel);
    await pumpEventQueue();

    origins.signIn('subsonic:', 'server-b');
    await pumpEventQueue();
    origins.signIn('subsonic:', 'server-a');
    await pumpEventQueue();

    expect(counts, <int>[1, 0, 1]);
  });

  test('a song that finishes while its server is signed out counts for none',
      () async {
    final DefaultPlayHistoryRepository repo = repository();
    origins.signIn('subsonic:', null);
    await repo.recordCompletion(_song);
    await repo.recordCompletion(_local);

    expect((await store.load()).stats.keys, <String>['/music/a.flac']);
    for (final String server in <String>['server-a', 'server-b']) {
      origins.signIn('subsonic:', server);
      expect(repo.current.hasPlayed('subsonic:48211'), isFalse);
    }
  });

  group('plays recorded before origins were', () {
    setUp(() async {
      await store.save(PlayHistory(stats: <String, TrackPlayStats>{
        'subsonic:48211': TrackPlayStats(playCount: 5, lastPlayedAt: t0),
      }));
    });

    test('count for the account they were settled to, with its new plays',
        () async {
      final DefaultPlayHistoryRepository repo = repository();
      await repo.recordCompletion(_song);

      expect(repo.current.playCountFor('subsonic:48211'), 6);
      expect(repo.current.lastPlayedFor('subsonic:48211'), isNot(t0));
    });

    test('never for another server', () async {
      origins.signIn('subsonic:', 'server-b');
      final PlayHistory onB = await repository().historyStream.first;
      expect(onB.hasPlayed('subsonic:48211'), isFalse);
    });

    test('nor for anyone when settled to nobody', () async {
      origins.legacyOrigins['subsonic:'] = noSongOrigin;
      final PlayHistory view = await repository().historyStream.first;
      expect(view.hasPlayed('subsonic:48211'), isFalse);
      // Kept, not dropped.
      expect((await store.load()).stats.keys, contains('subsonic:48211'));
    });
  });

  test('a moved local file keeps its count; remote keys are left alone',
      () async {
    final DefaultPlayHistoryRepository repo = repository();
    await repo.recordCompletion(_local);
    await repo.recordCompletion(_song);

    expect(
      await repo.reassignTrack(
        fromUri: '/music/a.flac',
        toUri: '/music/b.flac',
      ),
      isTrue,
    );

    expect(repo.current.playCountFor('/music/b.flac'), 1);
    expect(repo.current.playCountFor('subsonic:48211'), 1);
  });
}
