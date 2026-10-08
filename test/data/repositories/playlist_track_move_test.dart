import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/repositories/local_store_write_exception.dart';
import 'package:linthra/core/services/local_track_move_applier.dart';
import 'package:linthra/core/sources/local/local_catalog_reconciliation.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/synced_playlist_repository.dart';

const String _from = '/music/inbox/track05.flac';
const String _to = '/music/Bon Iver/05 Holocene.flac';

/// A playlist store whose disk can fill up, refusing writes the way the
/// preferences store does (#797).
class _DiskStore extends InMemoryPlaylistStore {
  bool refuse = false;
  int saves = 0;

  @override
  Future<void> save(List<Playlist> playlists) async {
    saves++;
    if (refuse) throw const LocalStoreWriteException(LocalStoreArea.playlists);
    return super.save(playlists);
  }
}

void main() {
  late _DiskStore store;
  late SyncedPlaylistRepository repo;
  late List<List<Playlist>> emitted;

  Future<void> seed(List<Playlist> playlists) async {
    store = _DiskStore();
    await store.save(playlists);
    store.saves = 0;
    repo = SyncedPlaylistRepository(store: store);
    emitted = <List<Playlist>>[];
    repo.playlistsStream.listen(emitted.add);
    await Future<void>.delayed(Duration.zero);
    emitted.clear();
  }

  tearDown(() => repo.dispose());

  /// A move the scan proved, handed over the way the library controller does.
  Future<void> move({String from = _from, String to = _to}) =>
      LocalTrackMoveApplier(
        <String, Object>{LocalTrackMoveApplier.playlists: repo},
      ).apply(
        LocalCatalogReconciliation(
          moves: <LocalTrackMove>[LocalTrackMove(from: from, to: to)],
        ),
      );

  Future<List<String>> songsOf(String id) async =>
      (await repo.getPlaylistById(id))!.trackIds;

  test('a moved song keeps its place in every playlist holding it (#794)',
      () async {
    final DateTime edited = DateTime.utc(2026, 1, 1);
    await seed(<Playlist>[
      Playlist(
        id: 'mix',
        name: 'Mix',
        trackIds: const <String>['/music/a.flac', _from, '/music/c.flac'],
        updatedAt: edited,
      ),
      const Playlist(id: 'last', name: 'Last', trackIds: <String>[_from]),
      const Playlist(
        id: 'other',
        name: 'Other',
        trackIds: <String>['/music/a.flac'],
      ),
    ]);
    final Playlist other = (await repo.getPlaylistById('other'))!;

    await move();

    expect(
      await songsOf('mix'),
      <String>['/music/a.flac', _to, '/music/c.flac'],
    );
    expect(await songsOf('last'), <String>[_to]);
    // Not an edit the listener made.
    expect((await repo.getPlaylistById('mix'))!.updatedAt, edited);
    expect(identical(await repo.getPlaylistById('other'), other), isTrue);
    expect(store.saves, 1);
    expect(
      (await store.load()).map((Playlist p) => p.trackIds),
      <List<String>>[
        <String>['/music/a.flac', _to, '/music/c.flac'],
        <String>[_to],
        <String>['/music/a.flac'],
      ],
    );
    await Future<void>.delayed(Duration.zero);
    expect(emitted, hasLength(1));
  });

  test('a playlist that already lists the new path keeps the earlier entry',
      () async {
    await seed(const <Playlist>[
      Playlist(
        id: 'new-first',
        name: 'A',
        trackIds: <String>[_to, '/music/a.flac', _from],
      ),
      Playlist(
        id: 'old-first',
        name: 'B',
        trackIds: <String>[_from, '/music/a.flac', _to],
      ),
    ]);

    await move();

    expect(await songsOf('new-first'), <String>[_to, '/music/a.flac']);
    expect(await songsOf('old-first'), <String>[_to, '/music/a.flac']);
  });

  test('nothing is saved when no playlist holds the moved song', () async {
    await seed(const <Playlist>[
      Playlist(id: 'p', name: 'P', trackIds: <String>['/music/a.flac']),
    ]);

    await move();

    expect(store.saves, 0);
    expect(await songsOf('p'), <String>['/music/a.flac']);
  });

  test('server songs and synced playlists are never rewritten', () async {
    await seed(const <Playlist>[
      Playlist(id: 'local', name: 'L', trackIds: <String>['subsonic:1']),
      Playlist(
        id: 'synced',
        name: 'S',
        source: PlaylistSource.subsonic,
        remoteId: 'srv-1',
        trackIds: <String>['subsonic:1'],
        syncState: PlaylistSyncState.synced,
      ),
    ]);

    await move(from: 'subsonic:1', to: 'subsonic:2');
    await move(from: 'subsonic:1', to: _to);
    await move(from: _from, to: 'subsonic:1');

    expect(await songsOf('local'), <String>['subsonic:1']);
    expect(await songsOf('synced'), <String>['subsonic:1']);
    expect(store.saves, 0);
  });

  test('a move the disk refuses changes nothing, and never throws', () async {
    await seed(const <Playlist>[
      Playlist(id: 'p', name: 'P', trackIds: <String>[_from, '/music/a.flac']),
    ]);

    store.refuse = true;
    await move();
    store.refuse = false;

    expect(await songsOf('p'), <String>[_from, '/music/a.flac']);
    expect((await store.load()).single.trackIds, <String>[
      _from,
      '/music/a.flac',
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(emitted, isEmpty);

    // The next save doesn't carry it either (#808).
    await repo.addTracks('p', <String>['/music/b.flac']);
    expect((await store.load()).single.trackIds, <String>[
      _from,
      '/music/a.flac',
      '/music/b.flac',
    ]);
  });
}
