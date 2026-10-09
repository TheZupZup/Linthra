import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/favorites_store.dart';
import 'package:linthra/core/repositories/local_store_write_exception.dart';
import 'package:linthra/core/repositories/playlist_store.dart';
import 'package:linthra/core/repositories/remote_sync_gateway.dart';
import 'package:linthra/data/repositories/synced_favorites_repository.dart';
import 'package:linthra/data/repositories/synced_playlist_repository.dart';

/// #843: whose hearts, queued writes and synced playlists are, across a
/// sign-out the disk refuses, a restart, and another account signing in.

Track _song(String id) => Track(id: id, title: id, uri: 'subsonic:$id');

/// One Subsonic server account: what is starred there and which playlists it
/// has, plus every write it received.
class _Account {
  final Set<String> starred = <String>{};
  final Map<String, RemotePlaylistData> playlists =
      <String, RemotePlaylistData>{};
  final List<String> writes = <String>[];
}

/// The servers the device can sign in to, by account key. A different user,
/// or the same user name on another server, is another key.
class _World {
  final Map<String, _Account> accounts = <String, _Account>{};

  /// The account signed in now, or null when signed out.
  String? signedIn;

  _Account operator [](String key) => accounts.putIfAbsent(key, _Account.new);

  _Account? get current => signedIn == null ? null : this[signedIn!];
}

class _Favorites implements RemoteFavoritesGateway {
  _Favorites(this.world);

  final _World world;

  @override
  String get uriScheme => 'subsonic:';

  @override
  bool get isConnected => world.signedIn != null;

  @override
  String? get accountKey => world.signedIn;

  @override
  Future<Set<String>> fetchFavoriteUris() async =>
      <String>{...?world.current?.starred};

  @override
  Future<void> pushFavorite(String trackUri, bool favorite) async {
    final _Account? account = world.current;
    if (account == null) return;
    account.writes.add('${favorite ? 'star' : 'unstar'} $trackUri');
    if (favorite) {
      account.starred.add(trackUri);
    } else {
      account.starred.remove(trackUri);
    }
  }
}

class _Playlists implements RemotePlaylistGateway {
  _Playlists(this.world);

  final _World world;
  int _created = 0;

  @override
  PlaylistSource get source => PlaylistSource.subsonic;

  @override
  bool get isConnected => world.signedIn != null;

  @override
  String? get accountKey => world.signedIn;

  @override
  bool get pushesRename => true;

  @override
  bool get pushesReorder => true;

  @override
  Future<RemotePlaylistListing> fetchPlaylists() async =>
      RemotePlaylistListing(<RemotePlaylistData>[
        ...?world.current?.playlists.values,
      ]);

  @override
  Future<String> createRemotePlaylist(
    String name,
    List<String> trackUris,
  ) async {
    final _Account account = world.current!;
    final String id = 'srv-${++_created}';
    account.writes.add('create $id');
    account.playlists[id] =
        RemotePlaylistData(remoteId: id, name: name, trackUris: trackUris);
    return id;
  }

  @override
  Future<void> syncMembership(
    String remoteId, {
    required List<String> orderedTrackUris,
    required List<String> added,
    required List<String> removed,
  }) async {
    final _Account account = world.current!;
    account.writes.add('songs $remoteId $orderedTrackUris');
    final RemotePlaylistData? old = account.playlists[remoteId];
    if (old == null) return;
    account.playlists[remoteId] = RemotePlaylistData(
      remoteId: remoteId,
      name: old.name,
      trackUris: orderedTrackUris,
    );
  }

  @override
  Future<void> renameRemote(String remoteId, String name) async {
    world.current!.writes.add('rename $remoteId $name');
  }

  @override
  Future<void> deleteRemote(String remoteId) async {
    world.current!.writes.add('delete $remoteId');
    world.current!.playlists.remove(remoteId);
  }
}

/// Playlists whose fetch answers for the account signed in when it was sent
/// (a Subsonic request keeps the session it started with), held on [hold].
class _HeldPlaylists extends _Playlists {
  _HeldPlaylists(super.world);

  Completer<void>? hold;

  @override
  Future<RemotePlaylistListing> fetchPlaylists() async {
    final _Account? asked = world.current;
    final Completer<void>? held = hold;
    if (held != null) await held.future;
    return RemotePlaylistListing(<RemotePlaylistData>[
      ...?asked?.playlists.values,
    ]);
  }
}

/// A favourites disk that can refuse writes and outlives a "restart" (a new
/// repository over the same store).
class _FavoritesDisk implements FavoritesStore {
  _FavoritesDisk([this.saved = FavoritesData.empty]);

  FavoritesData saved;
  bool refuse = false;

  @override
  Future<FavoritesData> load() async => saved;

  @override
  Future<void> save(FavoritesData data) async {
    if (refuse) {
      throw const LocalStoreWriteException(LocalStoreArea.favorites);
    }
    saved = data;
  }
}

class _PlaylistDisk implements PlaylistStore {
  _PlaylistDisk([List<Playlist>? saved]) : saved = saved ?? <Playlist>[];

  List<Playlist> saved;
  bool refuse = false;

  /// While set, a save waits on it before it is written.
  Completer<void>? hold;

  @override
  Future<List<Playlist>> load() async => saved;

  @override
  Future<void> save(List<Playlist> playlists) async {
    final Completer<void>? held = hold;
    if (held != null) await held.future;
    if (refuse) {
      throw const LocalStoreWriteException(LocalStoreArea.playlists);
    }
    saved = List<Playlist>.of(playlists);
  }
}

const String _alice = 'alice@server-a';
const String _bob = 'bob@server-a';
const String _aliceElsewhere = 'alice@server-b';

void main() {
  late _World world;

  setUp(() => world = _World());

  group('favourites', () {
    late _FavoritesDisk disk;

    setUp(() => disk = _FavoritesDisk());

    SyncedFavoritesRepository launch() {
      final SyncedFavoritesRepository repo = SyncedFavoritesRepository(
        store: disk,
        gateways: <RemoteFavoritesGateway>[_Favorites(world)],
      );
      addTearDown(repo.dispose);
      return repo;
    }

    /// Alice hearts two songs; one of the pushes never lands, so it stays
    /// queued. Then she signs out and the disk refuses to save that.
    Future<void> aliceSignsOutButTheDiskRefuses() async {
      world.signedIn = _alice;
      final SyncedFavoritesRepository repo = launch();
      await repo.refreshFromRemote();
      await repo.setFavorite(_song('1'), true);
      // Offline for this one: stays queued.
      final String? saved = world.signedIn;
      world.signedIn = null;
      await repo.setFavorite(_song('2'), true);
      world.signedIn = saved;
      expect(repo.pendingRemoteWriteCount, 1);
      expect(disk.saved.owners['subsonic:'], _alice);

      disk.refuse = true;
      world.signedIn = null;
      await expectLater(
        repo.clearRemote(providerScheme: 'subsonic:'),
        throwsA(isA<LocalStoreWriteException>()),
      );
      // Memory is signed out; the disk still has Alice's hearts and her
      // queued write, and says they are hers.
      expect(repo.isFavorite('subsonic:1'), isFalse);
      expect(disk.saved.pendingWrites, <String, bool>{'subsonic:2': true});
      disk.refuse = false;
    }

    test(
        'after a refused sign-out and a restart, the next account gets none '
        'of them', () async {
      await aliceSignsOutButTheDiskRefuses();
      world[_bob].starred.add('subsonic:99');

      // Restart: Bob signs in.
      world.signedIn = _bob;
      final SyncedFavoritesRepository repo = launch();
      await repo.refreshFromRemote();

      expect(world[_bob].writes, isEmpty, reason: "Alice's heart stays hers");
      expect(repo.isFavorite('subsonic:1'), isFalse);
      expect(repo.isFavorite('subsonic:2'), isFalse);
      expect(repo.isFavorite('subsonic:99'), isTrue);
      expect(repo.pendingRemoteWriteCount, 0);
      expect(disk.saved.owners['subsonic:'], _bob);
      expect(disk.saved.pendingWrites, isEmpty);
    });

    test(
        'a heart before the first refresh does not carry the old account\'s '
        'along', () async {
      await aliceSignsOutButTheDiskRefuses();

      world.signedIn = _bob;
      final SyncedFavoritesRepository repo = launch();
      await repo.setFavorite(_song('7'), true);

      expect(world[_bob].writes, <String>['star subsonic:7']);
      expect(repo.isFavorite('subsonic:1'), isFalse);
      expect(disk.saved.pendingWrites, isEmpty);

      await repo.refreshFromRemote();
      expect(world[_bob].writes, <String>['star subsonic:7']);
    });

    test('the same account signing back in gets its own queued write',
        () async {
      await aliceSignsOutButTheDiskRefuses();

      world.signedIn = _alice;
      final SyncedFavoritesRepository repo = launch();
      await repo.refreshFromRemote();

      expect(world[_alice].writes, <String>[
        'star subsonic:1',
        'star subsonic:2',
      ]);
      expect(repo.isFavorite('subsonic:2'), isTrue);
      expect(repo.pendingRemoteWriteCount, 0);
    });

    test('the same user name on another server is another account', () async {
      await aliceSignsOutButTheDiskRefuses();

      world.signedIn = _aliceElsewhere;
      final SyncedFavoritesRepository repo = launch();
      await repo.refreshFromRemote();

      expect(world[_aliceElsewhere].writes, isEmpty);
      expect(repo.isFavorite('subsonic:1'), isFalse);
    });

    test(
        'a heart made while the saved sign-in is still loading belongs to '
        'the account that was signed in', () async {
      world.signedIn = _alice;
      await launch().refreshFromRemote();

      // Next launch: the session hasn't loaded yet.
      world.signedIn = null;
      final SyncedFavoritesRepository repo = launch();
      await repo.setFavorite(_song('5'), true);
      expect(repo.pendingRemoteWriteCount, 1);

      world.signedIn = _alice;
      await repo.refreshFromRemote();
      expect(world[_alice].writes, <String>['star subsonic:5']);
    });

    test('...and never goes to a different account that loads instead',
        () async {
      world.signedIn = _alice;
      await launch().refreshFromRemote();

      world.signedIn = null;
      final SyncedFavoritesRepository repo = launch();
      await repo.setFavorite(_song('5'), true);

      world.signedIn = _bob;
      await repo.refreshFromRemote();
      expect(world[_bob].writes, isEmpty);
      expect(repo.isFavorite('subsonic:5'), isFalse);
    });

    test('a heart made after signing out is nobody\'s, across a restart too',
        () async {
      world.signedIn = _alice;
      final SyncedFavoritesRepository repo = launch();
      await repo.refreshFromRemote();
      world.signedIn = null;
      await repo.clearRemote(providerScheme: 'subsonic:');
      await repo.setFavorite(_song('3'), true);
      expect(repo.pendingRemoteWriteCount, 0);

      world.signedIn = _bob;
      await launch().refreshFromRemote();
      expect(world[_bob].writes, isEmpty);
    });

    test('a push still out when another account takes over settles nothing',
        () async {
      world.signedIn = _alice;
      final _Favorites gateway = _Favorites(world);
      final Completer<void> held = Completer<void>();
      final _HeldFavorites slow = _HeldFavorites(gateway, held);
      final SyncedFavoritesRepository repo = SyncedFavoritesRepository(
        store: disk,
        gateways: <RemoteFavoritesGateway>[slow],
      );
      addTearDown(repo.dispose);
      await repo.refreshFromRemote();

      final Future<void> hearting = repo.setFavorite(_song('4'), true);
      await pumpEventQueue();
      // Alice's push is out; Bob signs in on a disk that never heard of the
      // sign-out.
      world.signedIn = _bob;
      await repo.refreshFromRemote();
      held.complete();
      await hearting;

      expect(repo.isFavorite('subsonic:4'), isFalse);
      expect(repo.pendingRemoteWriteCount, 0);
      expect(world[_bob].writes, isEmpty);
    });

    test(
        'a claim the disk refuses still stands, and is made again after a '
        'restart', () async {
      await aliceSignsOutButTheDiskRefuses();

      world.signedIn = _bob;
      disk.refuse = true;
      final SyncedFavoritesRepository repo = launch();
      await repo.refreshFromRemote();
      expect(repo.isFavorite('subsonic:1'), isFalse);
      expect(world[_bob].writes, isEmpty);

      disk.refuse = false;
      final SyncedFavoritesRepository restarted = launch();
      await restarted.refreshFromRemote();
      expect(world[_bob].writes, isEmpty);
      expect(disk.saved.owners['subsonic:'], _bob);
    });

    test('hearts from before owners were kept are never pushed', () async {
      // Written by an older Linthra: no owners, so the queued write can't
      // be attributed. The store drops it on load (see
      // shared_preferences_favorites_store_test); here, what's left.
      disk = _FavoritesDisk(const FavoritesData(
        remoteIds: <String>{'subsonic:1'},
      ));
      world.signedIn = _bob;
      world[_bob].starred.add('subsonic:8');

      final SyncedFavoritesRepository repo = launch();
      await repo.refreshFromRemote();

      expect(world[_bob].writes, isEmpty);
      expect(repo.isFavorite('subsonic:1'), isFalse);
      expect(repo.isFavorite('subsonic:8'), isTrue);
    });
  });

  group('synced playlists', () {
    late _PlaylistDisk disk;

    setUp(() => disk = _PlaylistDisk());

    SyncedPlaylistRepository launch() {
      final SyncedPlaylistRepository repo = SyncedPlaylistRepository(
        store: disk,
        gateways: <RemotePlaylistGateway>[_Playlists(world)],
      );
      addTearDown(repo.dispose);
      return repo;
    }

    /// Alice has one synced playlist on her server, and one made here whose
    /// create never got through. She signs out; the disk refuses the save.
    Future<String> aliceSignsOutButTheDiskRefuses() async {
      world.signedIn = _alice;
      world[_alice].playlists['srv-a'] = const RemotePlaylistData(
        remoteId: 'srv-a',
        name: "Alice's mix",
        trackUris: <String>['subsonic:1', 'subsonic:2'],
      );
      final SyncedPlaylistRepository repo = launch();
      await repo.refreshFromRemote();
      final Playlist mix = (await repo.getAllPlaylists()).single;
      expect(mix.owner, _alice);
      await disk.save(<Playlist>[
        ...disk.saved,
        const Playlist(
          id: 'unsent',
          name: 'Never reached the server',
          source: PlaylistSource.subsonic,
          trackIds: <String>['subsonic:3'],
          syncState: PlaylistSyncState.syncFailed,
          owner: _alice,
        ),
      ]);

      world.signedIn = null;
      disk.refuse = true;
      await expectLater(
        repo.clearRemote(source: PlaylistSource.subsonic),
        throwsA(isA<LocalStoreWriteException>()),
      );
      disk.refuse = false;
      expect(
        disk.saved.map((Playlist p) => p.owner),
        <String?>[_alice, _alice],
      );
      return mix.id;
    }

    test(
        'after a refused sign-out and a restart, an edit is never pushed to '
        'the next account', () async {
      final String mix = await aliceSignsOutButTheDiskRefuses();
      // Bob's server happens to use the same playlist id.
      world[_bob].playlists['srv-a'] = const RemotePlaylistData(
        remoteId: 'srv-a',
        name: "Bob's playlist",
        trackUris: <String>['subsonic:50'],
      );

      world.signedIn = _bob;
      final SyncedPlaylistRepository repo = launch();
      // Edited before any refresh: Alice's playlist is still on screen.
      await repo.addTracks(mix, <String>['subsonic:9']);
      await repo.renamePlaylist(mix, 'Renamed');
      expect(world[_bob].writes, isEmpty);
      expect(
          world[_bob].playlists['srv-a']!.trackUris, <String>['subsonic:50']);

      await repo.refreshFromRemote();
      final List<Playlist> playlists = await repo.getAllPlaylists();
      expect(world[_bob].writes, isEmpty);
      // Bob's own playlist, as his server has it.
      final Playlist bobs = playlists.singleWhere(
        (Playlist p) => p.source == PlaylistSource.subsonic,
      );
      expect(bobs.name, "Bob's playlist");
      expect(bobs.trackIds, <String>['subsonic:50']);
      expect(bobs.owner, _bob);
      // Alice's unsent one stays, as a device playlist.
      final Playlist unsent =
          playlists.singleWhere((Playlist p) => p.id == 'unsent');
      expect(unsent.source, PlaylistSource.local);
      expect(unsent.owner, isNull);
      expect(unsent.trackIds, <String>['subsonic:3']);
    });

    test('a delete before the first refresh does not reach the next account',
        () async {
      final String mix = await aliceSignsOutButTheDiskRefuses();
      world[_bob].playlists['srv-a'] = const RemotePlaylistData(
        remoteId: 'srv-a',
        name: "Bob's playlist",
        trackUris: <String>[],
      );

      world.signedIn = _bob;
      await launch().deletePlaylist(mix);

      expect(world[_bob].writes, isEmpty);
      expect(world[_bob].playlists, contains('srv-a'));
    });

    test(
        'the same account signing back in keeps its playlist, and edits '
        'reach it', () async {
      final String mix = await aliceSignsOutButTheDiskRefuses();

      world.signedIn = _alice;
      final SyncedPlaylistRepository repo = launch();
      await repo.refreshFromRemote();
      await repo.addTracks(mix, <String>['subsonic:9']);

      expect(world[_alice].writes, <String>[
        'songs srv-a [subsonic:1, subsonic:2, subsonic:9]',
      ]);
      expect((await repo.getPlaylistById(mix))!.owner, _alice);
    });

    test('the same user name on another server is another account', () async {
      final String mix = await aliceSignsOutButTheDiskRefuses();

      world.signedIn = _aliceElsewhere;
      final SyncedPlaylistRepository repo = launch();
      await repo.addTracks(mix, <String>['subsonic:9']);
      await repo.refreshFromRemote();

      expect(world[_aliceElsewhere].writes, isEmpty);
      expect(await repo.getPlaylistById(mix), isNull);
    });

    test(
        'a playlist from before owners were kept is never pushed until a '
        'refresh adopts it', () async {
      disk = _PlaylistDisk(<Playlist>[
        const Playlist(
          id: 'old',
          name: 'Old mix',
          source: PlaylistSource.subsonic,
          remoteId: 'srv-a',
          trackIds: <String>['subsonic:1'],
          syncState: PlaylistSyncState.syncFailed,
        ),
        const Playlist(
          id: 'gone',
          name: 'Not on this server',
          source: PlaylistSource.subsonic,
          remoteId: 'srv-x',
          trackIds: <String>['subsonic:2'],
          syncState: PlaylistSyncState.synced,
        ),
      ]);
      world.signedIn = _bob;
      world[_bob].playlists['srv-a'] = const RemotePlaylistData(
        remoteId: 'srv-a',
        name: 'Server mix',
        trackUris: <String>['subsonic:40'],
      );
      final SyncedPlaylistRepository repo = launch();

      await repo.addTracks('old', <String>['subsonic:3']);
      await repo.renamePlaylist('old', 'Local name');
      await repo.deletePlaylist('gone');
      expect(world[_bob].writes, isEmpty);

      await repo.refreshFromRemote();
      // Adopted as the server has it, nothing of the old copy smuggled in.
      final Playlist adopted = (await repo.getPlaylistById('old'))!;
      expect(adopted.name, 'Server mix');
      expect(adopted.trackIds, <String>['subsonic:40']);
      expect(adopted.owner, _bob);
      expect(world[_bob].writes, isEmpty);

      // From now on it is Bob's, and his edits reach his server.
      await repo.addTracks('old', <String>['subsonic:41']);
      expect(world[_bob].writes, <String>[
        'songs srv-a [subsonic:40, subsonic:41]',
      ]);
    });

    test(
        'a refresh asked for another account does not join the previous '
        "account's refresh still out", () async {
      world.signedIn = _alice;
      world[_alice].playlists['srv-a'] = const RemotePlaylistData(
        remoteId: 'srv-a',
        name: "Alice's mix",
        trackUris: <String>['subsonic:1'],
      );
      world[_bob].playlists['srv-b'] = const RemotePlaylistData(
        remoteId: 'srv-b',
        name: "Bob's mix",
        trackUris: <String>['subsonic:2'],
      );
      final _HeldPlaylists gateway = _HeldPlaylists(world)
        ..hold = Completer<void>();
      final SyncedPlaylistRepository repo = SyncedPlaylistRepository(
        store: disk,
        gateways: <RemotePlaylistGateway>[gateway],
      );
      addTearDown(repo.dispose);

      final Future<Object?> alices = repo.refreshFromRemote();
      await pumpEventQueue();
      // Another account takes over without a sign-out in between.
      final Completer<void> aliceAnswer = gateway.hold!;
      gateway.hold = null;
      world.signedIn = _bob;
      final Future<Object?> bobs = repo.refreshFromRemote();
      aliceAnswer.complete();
      await alices;
      await bobs;

      final List<Playlist> playlists = await repo.getAllPlaylists();
      expect(playlists.map((Playlist p) => p.remoteId), <String?>['srv-b']);
      expect(playlists.single.owner, _bob);
    });

    test('a playlist made under one account is not created under the next',
        () async {
      world.signedIn = _alice;
      final SyncedPlaylistRepository repo = launch();

      // The playlist is still being saved here when the account changes
      // underneath it; its create goes out only after that.
      disk.hold = Completer<void>();
      final Future<Playlist> creating = repo.createPlaylist(
        'Mine',
        source: PlaylistSource.subsonic,
      );
      await pumpEventQueue();
      world.signedIn = _bob;
      disk.hold!.complete();
      disk.hold = null;
      final Playlist made = await creating;

      expect(world[_bob].writes, isEmpty);
      expect(made.owner, _alice);
      expect(made.remoteId, isNull);

      // Bob's refresh keeps it, as a device playlist.
      await repo.refreshFromRemote();
      final Playlist kept = (await repo.getPlaylistById(made.id))!;
      expect(kept.source, PlaylistSource.local);
      expect(world[_bob].writes, isEmpty);
    });

    test('owners survive the playlist store', () async {
      world.signedIn = _alice;
      final SyncedPlaylistRepository repo = launch();
      final Playlist made =
          await repo.createPlaylist('Mine', source: PlaylistSource.subsonic);
      expect(made.owner, _alice);
      expect(disk.saved.single.owner, _alice);
      expect(world[_alice].writes, <String>['create srv-1']);
    });
  });
}

/// A favourites gateway whose pushes wait on [held].
class _HeldFavorites implements RemoteFavoritesGateway {
  _HeldFavorites(this._inner, this._held);

  final _Favorites _inner;
  final Completer<void> _held;

  @override
  String get uriScheme => _inner.uriScheme;
  @override
  bool get isConnected => _inner.isConnected;
  @override
  String? get accountKey => _inner.accountKey;
  @override
  Future<Set<String>> fetchFavoriteUris() => _inner.fetchFavoriteUris();

  @override
  Future<void> pushFavorite(String trackUri, bool favorite) async {
    // The request has left for the account signed in now.
    final _Account? to = _inner.world.current;
    await _held.future;
    to?.writes.add('${favorite ? 'star' : 'unstar'} $trackUri');
    if (favorite) to?.starred.add(trackUri);
  }
}
