// Each store that takes a moved file's state says whether the move is saved,
// leaves its state exactly as it was when it isn't, and can be asked again
// without changing anything more once it is.
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/play_history.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/favorites_store.dart';
import 'package:linthra/core/repositories/local_store_write_exception.dart';
import 'package:linthra/core/repositories/remote_sync_gateway.dart';
import 'package:linthra/data/repositories/default_play_history_repository.dart';
import 'package:linthra/data/repositories/in_memory_favorites_store.dart';
import 'package:linthra/data/repositories/in_memory_library_added_store.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_play_history_store.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/recording_music_library_repository.dart';
import 'package:linthra/data/repositories/synced_favorites_repository.dart';
import 'package:linthra/data/repositories/synced_playlist_repository.dart';

const String _old = '/music/inbox/a.flac';
const String _new = '/music/Bon Iver/05.flac';

class _Favorites extends InMemoryFavoritesStore {
  _Favorites(super.initial);
  bool refuse = false;
  int saves = 0;

  @override
  Future<void> save(FavoritesData data) async {
    saves++;
    if (refuse) throw const LocalStoreWriteException(LocalStoreArea.favorites);
    return super.save(data);
  }
}

class _Playlists extends InMemoryPlaylistStore {
  bool refuse = false;
  int saves = 0;

  @override
  Future<void> save(List<Playlist> playlists) async {
    saves++;
    if (refuse) throw const LocalStoreWriteException(LocalStoreArea.playlists);
    return super.save(playlists);
  }
}

class _History extends InMemoryPlayHistoryStore {
  _History(super.initial);
  bool refuse = false;
  int saves = 0;

  @override
  Future<void> save(PlayHistory history) async {
    saves++;
    if (refuse) {
      throw const LocalStoreWriteException(LocalStoreArea.playHistory);
    }
    return super.save(history);
  }
}

class _Added extends InMemoryLibraryAddedStore {
  _Added(super.initial);
  bool refuse = false;

  @override
  Future<void> save(Map<String, DateTime> addedAt) async {
    if (refuse) {
      throw const LocalStoreWriteException(LocalStoreArea.libraryAdded);
    }
    return super.save(addedAt);
  }
}

/// A server that records every call made to it.
class _Server implements RemotePlaylistGateway {
  final List<String> calls = <String>[];

  @override
  PlaylistSource get source => PlaylistSource.subsonic;
  @override
  bool get isConnected => true;
  @override
  bool get pushesRename => true;
  @override
  bool get pushesReorder => true;
  @override
  Future<RemotePlaylistListing> fetchPlaylists() async {
    calls.add('fetch');
    return const RemotePlaylistListing(<RemotePlaylistData>[]);
  }

  @override
  Future<String> createRemotePlaylist(String name, List<String> uris) async {
    calls.add('create');
    return 'srv';
  }

  @override
  Future<void> syncMembership(
    String remoteId, {
    required List<String> orderedTrackUris,
    required List<String> added,
    required List<String> removed,
  }) async =>
      calls.add('songs');
  @override
  Future<void> renameRemote(String remoteId, String name) async =>
      calls.add('rename');
  @override
  Future<void> deleteRemote(String remoteId) async => calls.add('delete');
}

void main() {
  group('favorites', () {
    test('a refused move says so, and keeps the heart where it was', () async {
      final _Favorites store =
          _Favorites(const FavoritesData(localIds: <String>{_old}));
      final SyncedFavoritesRepository repo =
          SyncedFavoritesRepository(store: store);
      addTearDown(repo.dispose);

      store.refuse = true;
      expect(await repo.reassignTrack(fromUri: _old, toUri: _new), isFalse);
      expect(repo.isFavorite(_old), isTrue);
      expect(repo.isFavorite(_new), isFalse);

      store.refuse = false;
      expect(await repo.reassignTrack(fromUri: _old, toUri: _new), isTrue);
      expect((await store.load()).localIds, <String>{_new});

      // Asked again: nothing left at the old path, nothing saved.
      final int saves = store.saves;
      expect(await repo.reassignTrack(fromUri: _old, toUri: _new), isTrue);
      expect(store.saves, saves);
    });

    test('a server uri is not ours to move, and is not asked again', () async {
      final SyncedFavoritesRepository repo = SyncedFavoritesRepository(
        store: _Favorites(const FavoritesData(remoteIds: <String>{'x:1'})),
      );
      addTearDown(repo.dispose);

      expect(
        await repo.reassignTrack(fromUri: 'jellyfin:1', toUri: _new),
        isTrue,
      );
    });
  });

  group('playlists', () {
    late _Playlists store;
    late _Server server;
    late SyncedPlaylistRepository repo;
    final DateTime edited = DateTime.utc(2026, 1, 1);

    setUp(() async {
      store = _Playlists();
      server = _Server();
      await store.save(<Playlist>[
        Playlist(
          id: 'old-first',
          name: 'A',
          trackIds: const <String>[_old, '/x.flac', _new],
          updatedAt: edited,
        ),
        Playlist(
          id: 'new-first',
          name: 'B',
          trackIds: const <String>[_new, '/x.flac', _old],
          updatedAt: edited,
        ),
        const Playlist(
          id: 'synced',
          name: 'S',
          source: PlaylistSource.subsonic,
          remoteId: 'srv-1',
          trackIds: <String>['subsonic:1'],
          syncState: PlaylistSyncState.synced,
        ),
      ]);
      store.saves = 0;
      repo = SyncedPlaylistRepository(
        store: store,
        gateways: <RemotePlaylistGateway>[server],
      );
    });

    tearDown(() => repo.dispose());

    Future<List<String>> songsOf(String id) async =>
        (await repo.getPlaylistById(id))!.trackIds;

    test('a refused move changes nothing; asked again it lands like the first',
        () async {
      store.refuse = true;
      expect(await repo.reassignTrack(fromUri: _old, toUri: _new), isFalse);
      expect(await songsOf('old-first'), <String>[_old, '/x.flac', _new]);

      store.refuse = false;
      expect(await repo.reassignTrack(fromUri: _old, toUri: _new), isTrue);

      // The earlier entry stays, as for a move that landed the first time.
      expect(await songsOf('old-first'), <String>[_new, '/x.flac']);
      expect(await songsOf('new-first'), <String>[_new, '/x.flac']);
      expect((await repo.getPlaylistById('old-first'))!.updatedAt, edited);
      // A synced playlist is its server's, and nothing went to the server.
      expect(await songsOf('synced'), <String>['subsonic:1']);
      expect(server.calls, isEmpty);

      final int saves = store.saves;
      expect(await repo.reassignTrack(fromUri: _old, toUri: _new), isTrue);
      expect(store.saves, saves);
      expect(server.calls, isEmpty);
    });
  });

  group('play history', () {
    test('a refused move keeps the counts at the old path, saved or not',
        () async {
      final _History store = _History(PlayHistory(
        stats: <String, TrackPlayStats>{
          _old: TrackPlayStats(playCount: 3, lastPlayedAt: DateTime.utc(2026)),
        },
      ));
      final DefaultPlayHistoryRepository repo = DefaultPlayHistoryRepository(
        store: store,
        now: () => DateTime.utc(2026, 6),
      );
      addTearDown(repo.dispose);

      store.refuse = true;
      expect(await repo.reassignTrack(fromUri: _old, toUri: _new), isFalse);
      expect(repo.current.playCountFor(_old), 3);
      expect(repo.current.hasPlayed(_new), isFalse);

      // The next save that works doesn't carry the move along.
      store.refuse = false;
      await repo.recordCompletion(
        const Track(id: '/other.flac', title: 'o', uri: '/other.flac'),
      );
      expect((await store.load()).playCountFor(_old), 3);

      expect(await repo.reassignTrack(fromUri: _old, toUri: _new), isTrue);
      expect((await store.load()).playCountFor(_new), 3);
      expect((await store.load()).hasPlayed(_old), isFalse);

      final int saves = store.saves;
      expect(await repo.reassignTrack(fromUri: _old, toUri: _new), isTrue);
      expect(store.saves, saves);
    });
  });

  group('added on', () {
    test(
        'a move asked again after the catalog stamped the new path keeps '
        'the real date', () async {
      final DateTime longAgo = DateTime.utc(2021, 6, 1);
      final _Added added = _Added(<String, DateTime>{_old: longAgo});
      final RecordingMusicLibraryRepository repo =
          RecordingMusicLibraryRepository(
        delegate: InMemoryMusicLibraryRepository(),
        addedStore: added,
        now: () => DateTime.utc(2026, 9, 10),
      );

      added.refuse = true;
      expect(await repo.reassignTrack(fromUri: _old, toUri: _new), isFalse);
      expect((await added.load())[_old], longAgo);

      // The catalog write goes ahead and stamps the new path as new.
      added.refuse = false;
      await repo.upsertCatalog(
        sourceId: 'local',
        tracks: const <Track>[Track(id: _new, title: 'n', uri: _new)],
        albums: const [],
        artists: const [],
      );
      expect((await added.load())[_new], DateTime.utc(2026, 9, 10));

      expect(await repo.reassignTrack(fromUri: _old, toUri: _new), isTrue);
      expect((await added.load())[_new], longAgo);
      expect((await added.load()).containsKey(_old), isFalse);

      expect(await repo.reassignTrack(fromUri: _old, toUri: _new), isTrue);
      expect((await added.load())[_new], longAgo);
    });

    test('a refused stamp does not fail the catalog write', () async {
      final _Added added = _Added(<String, DateTime>{})..refuse = true;
      final RecordingMusicLibraryRepository repo =
          RecordingMusicLibraryRepository(
        delegate: InMemoryMusicLibraryRepository(),
        addedStore: added,
      );

      await repo.upsertCatalog(
        sourceId: 'local',
        tracks: const <Track>[Track(id: _new, title: 'n', uri: _new)],
        albums: const [],
        artists: const [],
      );

      expect(await repo.getAllTracks(), hasLength(1));
    });
  });
}
