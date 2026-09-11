import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/play_history.dart';
import 'package:linthra/core/repositories/favorites_store.dart';
import 'package:linthra/core/repositories/track_identity_reassignable.dart';
import 'package:linthra/core/services/local_track_move_applier.dart';
import 'package:linthra/core/sources/local/local_catalog_reconciliation.dart';
import 'package:linthra/data/repositories/default_play_history_repository.dart';
import 'package:linthra/data/repositories/in_memory_favorites_store.dart';
import 'package:linthra/data/repositories/in_memory_library_added_store.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_play_history_store.dart';
import 'package:linthra/data/repositories/recording_music_library_repository.dart';
import 'package:linthra/data/repositories/synced_favorites_repository.dart';

/// A collaborator with nothing keyed on a track uri, to prove those are simply
/// skipped rather than needing to grow the capability.
class _NotReassignable {}

class _RecordingTarget implements TrackIdentityReassignable {
  final List<String> calls = <String>[];

  @override
  Future<void> reassignTrack({
    required String fromUri,
    required String toUri,
  }) async {
    calls.add('$fromUri -> $toUri');
  }
}

void main() {
  group('LocalTrackMoveApplier', () {
    test('hands every move to every reassignable target', () async {
      final a = _RecordingTarget();
      final b = _RecordingTarget();

      final int applied = await LocalTrackMoveApplier(<Object>[
        a,
        _NotReassignable(),
        b,
      ]).apply(const LocalCatalogReconciliation(
        moves: <LocalTrackMove>[
          LocalTrackMove(from: '/old/1.flac', to: '/new/1.flac'),
          LocalTrackMove(from: '/old/2.flac', to: '/new/2.flac'),
        ],
      ));

      expect(applied, 2);
      expect(a.calls, <String>[
        '/old/1.flac -> /new/1.flac',
        '/old/2.flac -> /new/2.flac',
      ]);
      expect(b.calls, a.calls);
    });

    test('a reconciliation with only deletions moves nothing', () async {
      final target = _RecordingTarget();

      final int applied = await LocalTrackMoveApplier(<Object>[target]).apply(
        const LocalCatalogReconciliation(
          removedUris: <String>['/music/gone.flac'],
        ),
      );

      expect(applied, 0);
      expect(target.calls, isEmpty);
    });
  });

  group('play history follows a moved file', () {
    test('the play count and last-played time move with it', () async {
      final store = InMemoryPlayHistoryStore();
      final repository = DefaultPlayHistoryRepository(store: store);
      await store.save(PlayHistory(stats: <String, TrackPlayStats>{
        '/music/inbox/a.flac': TrackPlayStats(
          playCount: 12,
          lastPlayedAt: DateTime.utc(2026, 3, 1),
        ),
      }));

      await repository.reassignTrack(
        fromUri: '/music/inbox/a.flac',
        toUri: '/music/Bon Iver/05.flac',
      );

      final PlayHistory history = await store.load();
      expect(history.playCountFor('/music/Bon Iver/05.flac'), 12);
      expect(history.hasPlayed('/music/inbox/a.flac'), isFalse);
      await repository.dispose();
    });

    test('counts at both paths are folded together, never lost', () async {
      final store = InMemoryPlayHistoryStore();
      final repository = DefaultPlayHistoryRepository(store: store);
      await store.save(PlayHistory(stats: <String, TrackPlayStats>{
        '/old.flac': TrackPlayStats(
          playCount: 3,
          lastPlayedAt: DateTime.utc(2026, 1, 1),
        ),
        '/new.flac': TrackPlayStats(
          playCount: 4,
          lastPlayedAt: DateTime.utc(2026, 5, 1),
        ),
      }));

      await repository.reassignTrack(fromUri: '/old.flac', toUri: '/new.flac');

      final PlayHistory history = await store.load();
      expect(history.playCountFor('/new.flac'), 7);
      expect(history.lastPlayedFor('/new.flac'), DateTime.utc(2026, 5, 1));
      await repository.dispose();
    });

    test('a path with no history is a no-op', () async {
      final store = InMemoryPlayHistoryStore();
      final repository = DefaultPlayHistoryRepository(store: store);

      await repository.reassignTrack(fromUri: '/old.flac', toUri: '/new.flac');

      expect((await store.load()).stats, isEmpty);
      await repository.dispose();
    });
  });

  group('a heart follows a moved file', () {
    test('the local favourite moves to the new path', () async {
      final store = InMemoryFavoritesStore();
      await store.save(
        const FavoritesData(localIds: <String>{'/music/inbox/a.flac'}),
      );
      final repository = SyncedFavoritesRepository(store: store);

      await repository.reassignTrack(
        fromUri: '/music/inbox/a.flac',
        toUri: '/music/Bon Iver/05.flac',
      );

      expect(repository.isFavorite('/music/Bon Iver/05.flac'), isTrue);
      expect(repository.isFavorite('/music/inbox/a.flac'), isFalse);
      expect(
          (await store.load()).localIds, <String>{'/music/Bon Iver/05.flac'});
      await repository.dispose();
    });

    test('an un-hearted file stays un-hearted at its new path', () async {
      final store = InMemoryFavoritesStore();
      final repository = SyncedFavoritesRepository(store: store);

      await repository.reassignTrack(fromUri: '/old.flac', toUri: '/new.flac');

      expect(repository.isFavorite('/new.flac'), isFalse);
      await repository.dispose();
    });

    test('a server-owned uri is refused rather than rewritten', () async {
      final store = InMemoryFavoritesStore();
      await store.save(
        const FavoritesData(remoteIds: <String>{'jellyfin:101'}),
      );
      final repository = SyncedFavoritesRepository(store: store);

      await repository.reassignTrack(
        fromUri: 'jellyfin:101',
        toUri: '/music/a.flac',
      );

      final FavoritesData stored = await store.load();
      expect(stored.remoteIds, <String>{'jellyfin:101'});
      expect(stored.localIds, isEmpty);
      await repository.dispose();
    });
  });

  group('"added on" follows a moved file', () {
    test('the original date survives the move and the next scan', () async {
      final addedStore = InMemoryLibraryAddedStore();
      await addedStore.save(<String, DateTime>{
        '/music/inbox/a.flac': DateTime.utc(2021, 6, 1),
      });
      final repository = RecordingMusicLibraryRepository(
        delegate: InMemoryMusicLibraryRepository(),
        addedStore: addedStore,
        now: () => DateTime.utc(2026, 9, 10),
      );

      await repository.reassignTrack(
        fromUri: '/music/inbox/a.flac',
        toUri: '/music/Bon Iver/05.flac',
      );

      final Map<String, DateTime> addedAt = await addedStore.load();
      expect(addedAt['/music/Bon Iver/05.flac'], DateTime.utc(2021, 6, 1));
      expect(addedAt.containsKey('/music/inbox/a.flac'), isFalse);
    });
  });
}
