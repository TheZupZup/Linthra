import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/repositories/local_store_write_exception.dart';
import 'package:linthra/core/repositories/playlist_store.dart';
import 'package:linthra/core/repositories/remote_sync_gateway.dart';
import 'package:linthra/core/repositories/remote_sync_result.dart';
import 'package:linthra/data/repositories/synced_playlist_repository.dart';

/// A playlist store on a disk that can fill up: a refused write leaves the
/// saved list as it was and throws, as the preferences store does (#797).
class _DiskStore implements PlaylistStore {
  List<Playlist> saved = const <Playlist>[];
  bool refuse = false;

  /// Thrown by the next save instead of a refusal: a store that broke.
  Object? throwNext;

  bool _holdNext = false;
  Completer<bool> _release = Completer<bool>();
  Completer<void> _heldStarted = Completer<void>();

  /// Holds the next save until [releaseHeld] says whether it was written.
  void holdNextSave() {
    _holdNext = true;
    _release = Completer<bool>();
    _heldStarted = Completer<void>();
  }

  Future<void> get heldSaveStarted => _heldStarted.future;

  void releaseHeld({required bool written}) => _release.complete(written);

  @override
  Future<List<Playlist>> load() async => List<Playlist>.of(saved);

  @override
  Future<void> save(List<Playlist> playlists) async {
    final Object? broken = throwNext;
    throwNext = null;
    if (broken != null) throw broken;
    bool written = !refuse;
    if (_holdNext) {
      _holdNext = false;
      _heldStarted.complete();
      written = await _release.future;
    }
    if (!written) {
      throw const LocalStoreWriteException(LocalStoreArea.playlists);
    }
    saved = List<Playlist>.of(playlists);
  }
}

/// A server whose answers land at once, recording what reached it. [onWrite]
/// runs as a write lands, the way the disk can fill up while one is out.
class _Server implements RemotePlaylistGateway {
  List<RemotePlaylistData> playlists = <RemotePlaylistData>[];
  final List<String> calls = <String>[];
  void Function()? onWrite;

  Completer<void>? _fetchGate;
  Completer<void> _fetchStarted = Completer<void>();

  void holdFetch() {
    _fetchGate = Completer<void>();
    _fetchStarted = Completer<void>();
  }

  Future<void> get fetchStarted => _fetchStarted.future;

  void releaseFetch() => _fetchGate!.complete();

  @override
  PlaylistSource get source => PlaylistSource.subsonic;

  @override
  bool get isConnected => true;

  @override
  String? get accountKey => 'account-a';

  @override
  bool get pushesRename => true;

  @override
  bool get pushesReorder => true;

  @override
  Future<RemotePlaylistListing> fetchPlaylists() async {
    final List<RemotePlaylistData> answer = List.of(playlists);
    if (!_fetchStarted.isCompleted) _fetchStarted.complete();
    final Completer<void>? gate = _fetchGate;
    if (gate != null) await gate.future;
    return RemotePlaylistListing(answer);
  }

  @override
  Future<String> createRemotePlaylist(
    String name,
    List<String> trackUris,
  ) async {
    calls.add('create $name');
    onWrite?.call();
    playlists = <RemotePlaylistData>[
      ...playlists,
      RemotePlaylistData(remoteId: 'srv-$name', name: name, trackUris: []),
    ];
    return 'srv-$name';
  }

  @override
  Future<void> syncMembership(
    String remoteId, {
    required List<String> orderedTrackUris,
    required List<String> added,
    required List<String> removed,
  }) async {
    calls.add('songs $remoteId ${orderedTrackUris.join(',')}');
    onWrite?.call();
    playlists = <RemotePlaylistData>[
      for (final RemotePlaylistData p in playlists)
        p.remoteId == remoteId
            ? RemotePlaylistData(
                remoteId: remoteId,
                name: p.name,
                trackUris: List<String>.of(orderedTrackUris),
              )
            : p,
    ];
  }

  @override
  Future<void> renameRemote(String remoteId, String name) async {
    calls.add('rename $remoteId $name');
    onWrite?.call();
  }

  @override
  Future<void> deleteRemote(String remoteId) async {
    calls.add('delete $remoteId');
    onWrite?.call();
  }
}

Matcher get _refusedWrite => throwsA(isA<LocalStoreWriteException>());

/// Lets the stream deliver what was emitted so far.
Future<void> _delivered() => Future<void>.delayed(Duration.zero);

void main() {
  late _DiskStore store;
  late _Server server;
  late SyncedPlaylistRepository repo;
  late List<List<Playlist>> emitted;
  int ids = 0;

  setUp(() async {
    store = _DiskStore();
    server = _Server();
    ids = 0;
    repo = SyncedPlaylistRepository(
      store: store,
      gateways: <RemotePlaylistGateway>[server],
      idGenerator: () => 'pl-${ids++}',
    );
    emitted = <List<Playlist>>[];
    repo.playlistsStream.listen(emitted.add);
    await _delivered();
    emitted.clear();
  });

  tearDown(() => repo.dispose());

  Future<Playlist> only(String id) async => (await repo.getPlaylistById(id))!;

  /// Runs [edit] against a disk that refuses it, expecting it to throw and to
  /// leave nothing behind: not in memory, not on the stream, not on the server.
  Future<void> refused(Future<Object?> Function() edit) async {
    final List<Playlist> before = await repo.getAllPlaylists();
    final List<Playlist> savedBefore = store.saved;
    final int callsBefore = server.calls.length;
    await _delivered();
    emitted.clear();
    store.refuse = true;
    await expectLater(edit(), _refusedWrite);
    store.refuse = false;
    await _delivered();
    expect(await repo.getAllPlaylists(), before);
    expect(store.saved, savedBefore);
    expect(emitted, isEmpty);
    expect(server.calls.length, callsBefore);
  }

  group('a playlist edit whose save fails (#808)', () {
    test('create is not kept, and the next create saves only itself', () async {
      await refused(() => repo.createPlaylist('Lost'));
      await refused(
        () => repo.createPlaylist('Lost', source: PlaylistSource.subsonic),
      );

      await repo.createPlaylist('Kept');
      expect(store.saved.map((Playlist p) => p.name), <String>['Kept']);
    });

    test('add, remove, restore and reorder change nothing, then or later',
        () async {
      final Playlist p = await repo.createPlaylist('Mix');
      await repo.addTracks(p.id, <String>['a', 'b', 'c']);

      await refused(() => repo.addTracks(p.id, <String>['d']));
      await refused(() => repo.removeTrack(p.id, 'b'));
      await refused(() => repo.reorderTracks(p.id, 0, 3));
      await repo.removeTrack(p.id, 'c');
      await refused(() => repo.restoreTrack(p.id, 'c', <int>[2]));

      await repo.renamePlaylist(p.id, 'Mix 2');
      expect(store.saved.single.trackIds, <String>['a', 'b']);
      expect(store.saved.single.name, 'Mix 2');
    });

    test('rename and delete change nothing, and reach no server', () async {
      final Playlist p =
          await repo.createPlaylist('Synced', source: PlaylistSource.subsonic);
      expect((await only(p.id)).remoteId, 'srv-Synced');

      await refused(() => repo.renamePlaylist(p.id, 'Renamed'));
      await refused(() => repo.addTracks(p.id, <String>['subsonic:1']));
      await refused(() => repo.deletePlaylist(p.id));

      expect((await only(p.id)).name, 'Synced');
      expect(server.calls, <String>['create Synced']);
    });

    test('an edit made while a failing save is out is saved without it',
        () async {
      final Playlist p = await repo.createPlaylist('Mix');

      store.holdNextSave();
      final Future<void> first = repo.addTracks(p.id, <String>['a']);
      await store.heldSaveStarted;
      final Future<void> second = repo.addTracks(p.id, <String>['b']);

      store.releaseHeld(written: false);
      await expectLater(first, _refusedWrite);
      await second;

      expect((await only(p.id)).trackIds, <String>['b']);
      expect(store.saved.single.trackIds, <String>['b']);
    });

    test('two edits saved at once both stand', () async {
      final Playlist p = await repo.createPlaylist('Mix');

      store.holdNextSave();
      final Future<void> first = repo.addTracks(p.id, <String>['a']);
      await store.heldSaveStarted;
      final Future<void> second = repo.addTracks(p.id, <String>['b']);

      store.releaseHeld(written: true);
      await first;
      await second;

      expect((await only(p.id)).trackIds, <String>['a', 'b']);
      expect(store.saved.single.trackIds, <String>['a', 'b']);
    });

    test('an edit that failed during a refresh does not outlive its answer',
        () async {
      server.playlists = <RemotePlaylistData>[
        const RemotePlaylistData(
          remoteId: 'srv-1',
          name: 'Server',
          trackUris: <String>['subsonic:1'],
        ),
      ];
      await repo.refreshFromRemote();
      final Playlist synced = (await repo.getAllPlaylists()).single;

      // Deleted on the server, and the answer saying so comes back after the
      // listener tried to add to it here.
      server.playlists = <RemotePlaylistData>[];
      server.holdFetch();
      final Future<PlaylistSyncResult> refresh = repo.refreshFromRemote();
      await server.fetchStarted;
      store.refuse = true;
      await expectLater(
        repo.addTracks(synced.id, <String>['subsonic:2']),
        _refusedWrite,
      );
      store.refuse = false;
      server.releaseFetch();
      await refresh;

      // Nothing was edited, so the answer applies: the server deleted it.
      expect(await repo.getAllPlaylists(), isEmpty);
      expect(server.calls, isEmpty);
    });
  });

  group('what the server confirmed stands when its save fails (#808)', () {
    test('a create keeps the server id it was given', () async {
      server.onWrite = () => store.refuse = true;

      final Playlist created =
          await repo.createPlaylist('Synced', source: PlaylistSource.subsonic);

      expect(created.remoteId, 'srv-Synced');
      expect((await only(created.id)).remoteId, 'srv-Synced');
      expect((await only(created.id)).syncState, PlaylistSyncState.synced);

      // A refresh doesn't import the server playlist again beside it, and the
      // next save that lands has its server id.
      store.refuse = false;
      server.onWrite = null;
      await repo.refreshFromRemote();
      expect(await repo.getAllPlaylists(), hasLength(1));
      await repo.createPlaylist('Local');
      expect(store.saved.first.remoteId, 'srv-Synced');
    });

    test('an edit that saved does not fail over its sync state', () async {
      final Playlist p =
          await repo.createPlaylist('Synced', source: PlaylistSource.subsonic);
      server.onWrite = () => store.refuse = true;

      await repo.addTracks(p.id, <String>['subsonic:1']);

      expect((await only(p.id)).trackIds, <String>['subsonic:1']);
      expect((await only(p.id)).syncState, PlaylistSyncState.synced);
      expect(store.saved.single.trackIds, <String>['subsonic:1']);
    });

    test('signing out drops the synced playlists anyway', () async {
      await repo.createPlaylist('Synced', source: PlaylistSource.subsonic);
      await repo.createPlaylist('Local');

      store.refuse = true;
      await expectLater(
        repo.clearRemote(source: PlaylistSource.subsonic),
        _refusedWrite,
      );
      await _delivered();

      expect(
        (await repo.getAllPlaylists()).map((Playlist p) => p.name),
        <String>['Local'],
      );
      expect(emitted.last.map((Playlist p) => p.name), <String>['Local']);
    });
  });

  test('a refresh whose merge could not be saved changes nothing', () async {
    server.playlists = <RemotePlaylistData>[
      const RemotePlaylistData(
        remoteId: 'srv-1',
        name: 'Server',
        trackUris: <String>['subsonic:1'],
      ),
    ];
    store.refuse = true;
    await expectLater(repo.refreshFromRemote(), _refusedWrite);
    store.refuse = false;
    await _delivered();

    expect(await repo.getAllPlaylists(), isEmpty);
    expect(emitted, isEmpty);

    // The next one that can be saved imports it, once.
    await repo.refreshFromRemote();
    expect((await repo.getAllPlaylists()).single.remoteId, 'srv-1');
    expect(store.saved.single.remoteId, 'srv-1');
  });

  test('a store that breaks once does not stop the edits after it', () async {
    store.throwNext = StateError('broken');
    await expectLater(
      repo.createPlaylist('Lost'),
      throwsA(isA<StateError>()),
    );
    expect(await repo.getAllPlaylists(), isEmpty);

    await repo.createPlaylist('Kept');
    expect(store.saved.map((Playlist p) => p.name), <String>['Kept']);
  });
}
