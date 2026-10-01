import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/remote_sync_gateway.dart';
import 'package:linthra/core/repositories/remote_sync_result.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/core/sources/subsonic/subsonic_api.dart';
import 'package:linthra/core/sources/subsonic/subsonic_exception.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/jellyfin_playlist_gateway.dart';
import 'package:linthra/data/repositories/subsonic_playlist_gateway.dart';
import 'package:linthra/data/repositories/synced_playlist_repository.dart';

import '../../core/sources/jellyfin/fake_jellyfin_client.dart';
import '../../core/sources/subsonic/fake_subsonic_client.dart';

const String _token = 'super-secret-token-1234567890';

const JellyfinSession _session = JellyfinSession(
  baseUrl: 'https://music.example.com',
  userId: 'user-1',
  accessToken: _token,
  deviceId: 'device-1',
);

const SubsonicSession _subsonicSession = SubsonicSession(
  baseUrl: 'https://nav.example.com',
  username: 'alice',
  salt: 'salt1',
  token: 'tok1',
);

void main() {
  group('SyncedPlaylistRepository (local)', () {
    late InMemoryPlaylistStore store;
    late SyncedPlaylistRepository repository;
    late int counter;

    setUp(() {
      store = InMemoryPlaylistStore();
      counter = 0;
      repository = SyncedPlaylistRepository(
        store: store,
        idGenerator: () => 'pl-${counter++}',
        now: () => DateTime(2024, 1, 1),
      );
    });

    test('creates a local, local-only playlist and persists it', () async {
      final Playlist created = await repository.createPlaylist('My Mix');
      expect(created.name, 'My Mix');
      expect(created.source, PlaylistSource.local);
      expect(created.syncState, PlaylistSyncState.localOnly);
      expect(created.createdAt, DateTime(2024, 1, 1));

      // Persisted to the store.
      expect(await store.load(), hasLength(1));
      expect((await repository.getAllPlaylists()).single.name, 'My Mix');
    });

    test('renames a playlist', () async {
      final Playlist created = await repository.createPlaylist('Old');
      await repository.renamePlaylist(created.id, 'New', description: 'desc');
      final Playlist? updated = await repository.getPlaylistById(created.id);
      expect(updated!.name, 'New');
      expect(updated.description, 'desc');
    });

    test('deletes a playlist', () async {
      final Playlist created = await repository.createPlaylist('Mix');
      await repository.deletePlaylist(created.id);
      expect(await repository.getAllPlaylists(), isEmpty);
      expect(await store.load(), isEmpty);
    });

    test('adds a track once (no duplicate)', () async {
      final Playlist created = await repository.createPlaylist('Mix');
      await repository.addTrack(created.id, 't1');
      await repository.addTrack(created.id, 't1');
      final Playlist? updated = await repository.getPlaylistById(created.id);
      expect(updated!.trackIds, <String>['t1']);
    });

    test('adds multiple tracks preserving order and skipping dupes', () async {
      final Playlist created = await repository.createPlaylist('Mix');
      await repository.addTracks(created.id, <String>['a', 'b']);
      await repository.addTracks(created.id, <String>['b', 'c']);
      final Playlist? updated = await repository.getPlaylistById(created.id);
      expect(updated!.trackIds, <String>['a', 'b', 'c']);
    });

    test('removes a track', () async {
      final Playlist created = await repository.createPlaylist('Mix');
      await repository.addTracks(created.id, <String>['a', 'b', 'c']);
      await repository.removeTrack(created.id, 'b');
      final Playlist? updated = await repository.getPlaylistById(created.id);
      expect(updated!.trackIds, <String>['a', 'c']);
    });

    test('same-id tracks from different providers are distinct members',
        () async {
      // jellyfin:101 and subsonic:101 share the bare id 101; adding the second
      // is a real add, not a duplicate, and removing one keeps the other.
      final Playlist created = await repository.createPlaylist('Mix');
      await repository.addTrack(created.id, 'jellyfin:101');
      await repository.addTrack(created.id, 'subsonic:101');
      // Re-adding an existing uri is still a no-op.
      await repository.addTrack(created.id, 'jellyfin:101');
      expect((await repository.getPlaylistById(created.id))!.trackIds,
          <String>['jellyfin:101', 'subsonic:101']);

      await repository.removeTrack(created.id, 'jellyfin:101');
      expect((await repository.getPlaylistById(created.id))!.trackIds,
          <String>['subsonic:101']);
    });

    test('reorders tracks (ReorderableListView index convention)', () async {
      final Playlist created = await repository.createPlaylist('Mix');
      await repository.addTracks(created.id, <String>['a', 'b', 'c']);
      // Move 'a' (0) to after 'c': newIndex == length (3).
      await repository.reorderTracks(created.id, 0, 3);
      final Playlist? updated = await repository.getPlaylistById(created.id);
      expect(updated!.trackIds, <String>['b', 'c', 'a']);
    });

    test('watch stream emits the current set and every change', () async {
      final List<List<String>> emissions = <List<String>>[];
      final sub = repository.playlistsStream.listen(
        (List<Playlist> ps) =>
            emissions.add(ps.map((Playlist p) => p.name).toList()),
      );
      // Let the generator deliver its initial snapshot and subscribe to the
      // change stream before mutating, so the change isn't missed.
      await pumpEventQueue();
      await repository.createPlaylist('First');
      await pumpEventQueue();
      await sub.cancel();
      expect(emissions.first, isEmpty);
      expect(emissions.last, <String>['First']);
    });

    test('markSyncState records the state and a secret-free error', () async {
      final Playlist created = await repository.createPlaylist('Mix');
      await repository.markSyncState(
        created.id,
        PlaylistSyncState.syncFailed,
        error: 'Something went wrong',
      );
      final Playlist? updated = await repository.getPlaylistById(created.id);
      expect(updated!.syncState, PlaylistSyncState.syncFailed);
      expect(updated.lastSyncError, 'Something went wrong');
    });

    test('requesting a Jellyfin playlist while offline stays local', () async {
      // No client/session configured: a jellyfin request falls back to local.
      final Playlist created = await repository.createPlaylist(
        'Mix',
        source: PlaylistSource.jellyfin,
      );
      expect(created.source, PlaylistSource.local);
      expect(created.syncState, PlaylistSyncState.localOnly);
    });

    test('refreshFromRemote without a client reports not configured', () async {
      final PlaylistSyncResult result = await repository.refreshFromRemote();
      expect(result.outcome, RemoteSyncOutcome.notConfigured);
    });
  });

  group('SyncedPlaylistRepository (Jellyfin sync)', () {
    late InMemoryPlaylistStore store;
    late FakeJellyfinClient client;
    late SyncedPlaylistRepository repository;
    late int counter;

    setUp(() {
      store = InMemoryPlaylistStore();
      client = FakeJellyfinClient();
      counter = 0;
      repository = SyncedPlaylistRepository(
        store: store,
        gateways: <RemotePlaylistGateway>[
          JellyfinPlaylistGateway(
            client: client,
            session: () => _session,
          ),
        ],
        idGenerator: () => 'pl-${counter++}',
        now: () => DateTime(2024, 1, 1),
      );
    });

    test('creates a remote playlist and records the server id', () async {
      client.createdPlaylistId = 'srv-9';
      final Playlist created = await repository.createPlaylist(
        'Server Mix',
        source: PlaylistSource.jellyfin,
      );
      expect(client.createPlaylistCalls.single.name, 'Server Mix');
      expect(created.source, PlaylistSource.jellyfin);
      expect(created.remoteId, 'srv-9');
      expect(created.syncState, PlaylistSyncState.synced);
      expect(created.lastSyncError, isNull);
    });

    test('adds a Jellyfin track to a Jellyfin playlist on the server',
        () async {
      client.createdPlaylistId = 'srv-1';
      final Playlist created = await repository.createPlaylist(
        'Server Mix',
        source: PlaylistSource.jellyfin,
      );
      await repository.addTrack(created.id, 'jellyfin:jelly-item-7');
      expect(client.addItemCalls.single.playlistId, 'srv-1');
      // Membership is stored as a jellyfin: uri but the server gets the bare id.
      expect(client.addItemCalls.single.itemIds, <String>['jelly-item-7']);
      final Playlist? updated = await repository.getPlaylistById(created.id);
      expect(updated!.trackIds, <String>['jellyfin:jelly-item-7']);
      expect(updated.syncState, PlaylistSyncState.synced);
    });

    test('deletes the server playlist when deleting a synced one', () async {
      client.createdPlaylistId = 'srv-3';
      final Playlist created = await repository.createPlaylist(
        'Server Mix',
        source: PlaylistSource.jellyfin,
      );
      await repository.deletePlaylist(created.id);
      expect(client.deletedPlaylistIds, <String>['srv-3']);
      expect(await repository.getAllPlaylists(), isEmpty);
    });

    test('expired session maps to a friendly, secret-free sync error',
        () async {
      client.playlistError = JellyfinException.unauthorized();
      final Playlist created = await repository.createPlaylist(
        'Server Mix',
        source: PlaylistSource.jellyfin,
      );
      expect(created.syncState, PlaylistSyncState.syncFailed);
      expect(created.lastSyncError, isNotNull);
      expect(created.lastSyncError, JellyfinException.unauthorized().message);
      // The error never leaks the token, and the playlist never stores it.
      expect(created.lastSyncError, isNot(contains(_token)));
      expect(created.remoteId, isNull);
    });

    test('unreachable server maps to a friendly sync error', () async {
      client.playlistError = JellyfinException.notReachable();
      final Playlist created = await repository.createPlaylist(
        'Server Mix',
        source: PlaylistSource.jellyfin,
      );
      expect(created.syncState, PlaylistSyncState.syncFailed);
      expect(created.lastSyncError, JellyfinException.notReachable().message);
      expect(created.lastSyncError, isNot(contains(_token)));
    });

    test('a failed membership push never throws and flags syncFailed',
        () async {
      client.createdPlaylistId = 'srv-2';
      final Playlist created = await repository.createPlaylist(
        'Server Mix',
        source: PlaylistSource.jellyfin,
      );
      // Now make the next server call fail.
      client.playlistError = JellyfinException.notReachable();
      await repository.addTrack(created.id, 'jellyfin:jelly-item-1');
      final Playlist? updated = await repository.getPlaylistById(created.id);
      // The local add still stands…
      expect(updated!.trackIds, contains('jellyfin:jelly-item-1'));
      // …but the sync state is honest about the failure.
      expect(updated.syncState, PlaylistSyncState.syncFailed);
    });

    test('imports remote playlists on refresh', () async {
      client.playlists = <JellyfinPlaylistDto>[
        const JellyfinPlaylistDto(id: 'srv-77', name: 'From Server'),
      ];
      client.playlistEntries['srv-77'] = <JellyfinPlaylistEntry>[
        const JellyfinPlaylistEntry(itemId: 'a', playlistItemId: 'e-a'),
        const JellyfinPlaylistEntry(itemId: 'b', playlistItemId: 'e-b'),
      ];
      await repository.refreshFromRemote();
      final List<Playlist> all = await repository.getAllPlaylists();
      expect(all, hasLength(1));
      expect(all.single.name, 'From Server');
      expect(all.single.remoteId, 'srv-77');
      expect(all.single.source, PlaylistSource.jellyfin);
      // Server item ids are namespaced to jellyfin: uris on import.
      expect(all.single.trackIds, <String>['jellyfin:a', 'jellyfin:b']);
      expect(all.single.syncState, PlaylistSyncState.synced);
    });

    test('refreshFromRemote reports the synced playlist count', () async {
      client.playlists = const <JellyfinPlaylistDto>[
        JellyfinPlaylistDto(id: 'srv-1', name: 'A'),
        JellyfinPlaylistDto(id: 'srv-2', name: 'B'),
      ];
      final PlaylistSyncResult result = await repository.refreshFromRemote();
      expect(result.didSync, isTrue);
      expect(result.playlistCount, 2);
    });

    test('refreshFromRemote reports a failure when the server is unreachable',
        () async {
      client.playlistError = JellyfinException.notReachable();
      final PlaylistSyncResult result = await repository.refreshFromRemote();
      expect(result.didFail, isTrue);
    });

    test('repeated refresh does not duplicate the imported playlist', () async {
      client.playlists = const <JellyfinPlaylistDto>[
        JellyfinPlaylistDto(id: 'srv-1', name: 'Mix'),
      ];
      client.playlistEntries['srv-1'] = const <JellyfinPlaylistEntry>[
        JellyfinPlaylistEntry(itemId: 'a', playlistItemId: 'e-a'),
      ];
      await repository.refreshFromRemote();
      await repository.refreshFromRemote();
      final List<Playlist> all = await repository.getAllPlaylists();
      expect(all.where((Playlist p) => p.remoteId == 'srv-1'), hasLength(1));
    });

    test('a remote rename updates the local synced playlist on refresh',
        () async {
      client.playlists = const <JellyfinPlaylistDto>[
        JellyfinPlaylistDto(id: 'srv-1', name: 'Old Name'),
      ];
      client.playlistEntries['srv-1'] = const <JellyfinPlaylistEntry>[
        JellyfinPlaylistEntry(itemId: 'a', playlistItemId: 'e-a'),
      ];
      await repository.refreshFromRemote();

      // The server renames the playlist; the next refresh adopts the new name.
      client.playlists = const <JellyfinPlaylistDto>[
        JellyfinPlaylistDto(id: 'srv-1', name: 'New Name'),
      ];
      await repository.refreshFromRemote();

      final List<Playlist> all = await repository.getAllPlaylists();
      expect(all, hasLength(1));
      expect(all.single.name, 'New Name');
      expect(all.single.remoteId, 'srv-1');
    });

    test('a playlist deleted on the server is dropped on the next refresh',
        () async {
      client.playlists = const <JellyfinPlaylistDto>[
        JellyfinPlaylistDto(id: 'srv-1', name: 'Mix'),
      ];
      client.playlistEntries['srv-1'] = const <JellyfinPlaylistEntry>[
        JellyfinPlaylistEntry(itemId: 'a', playlistItemId: 'e-a'),
      ];
      await repository.refreshFromRemote();
      expect(await repository.getAllPlaylists(), hasLength(1));

      // The server no longer reports it — it was deleted there.
      client.playlists = const <JellyfinPlaylistDto>[];
      await repository.refreshFromRemote();
      expect(await repository.getAllPlaylists(), isEmpty);
    });

    test('refresh keeps a local-only playlist while pruning a deleted remote',
        () async {
      final Playlist local = await repository.createPlaylist('Local Mix');
      client.playlists = const <JellyfinPlaylistDto>[
        JellyfinPlaylistDto(id: 'srv-1', name: 'Server Mix'),
      ];
      client.playlistEntries['srv-1'] = const <JellyfinPlaylistEntry>[
        JellyfinPlaylistEntry(itemId: 'a', playlistItemId: 'e-a'),
      ];
      await repository.refreshFromRemote();
      expect(await repository.getAllPlaylists(), hasLength(2));

      // The server deletes its playlist; the local-only one must survive.
      client.playlists = const <JellyfinPlaylistDto>[];
      await repository.refreshFromRemote();
      final List<Playlist> all = await repository.getAllPlaylists();
      expect(all, hasLength(1));
      expect(all.single.id, local.id);
      expect(all.single.source, PlaylistSource.local);
    });

    test('clearRemote drops synced playlists but keeps local-only ones',
        () async {
      final Playlist local = await repository.createPlaylist('Local Mix');
      client.createdPlaylistId = 'srv-9';
      await repository.createPlaylist(
        'Server Mix',
        source: PlaylistSource.jellyfin,
      );
      expect(await repository.getAllPlaylists(), hasLength(2));

      await repository.clearRemote();

      final List<Playlist> all = await repository.getAllPlaylists();
      expect(all, hasLength(1));
      expect(all.single.id, local.id);
      expect(all.single.source, PlaylistSource.local);
    });

    test('no token is ever stored in playlist metadata', () async {
      client.createdPlaylistId = 'srv-1';
      final Playlist created = await repository.createPlaylist(
        'Server Mix',
        source: PlaylistSource.jellyfin,
      );
      await repository.addTrack(created.id, 'jellyfin:jelly-item-1');
      for (final Playlist p in await repository.getAllPlaylists()) {
        expect(p.remoteId, isNot(contains(_token)));
        expect(p.id, isNot(contains(_token)));
        expect(p.lastSyncError ?? '', isNot(contains(_token)));
        for (final String trackUri in p.trackIds) {
          expect(trackUri, isNot(contains(_token)));
        }
      }
    });
  });

  group('SyncedPlaylistRepository (legacy bare-id membership migration)', () {
    late InMemoryPlaylistStore store;

    setUp(() {
      store = InMemoryPlaylistStore();
    });

    SyncedPlaylistRepository build({
      Future<List<Track>> Function()? catalog,
    }) {
      return SyncedPlaylistRepository(
        store: store,
        idGenerator: () => 'pl-x',
        now: () => DateTime(2024, 1, 1),
        catalogForMigration: catalog,
      );
    }

    test('namespaces a Jellyfin playlist\'s bare item ids (no oracle needed)',
        () async {
      await store.save(<Playlist>[
        const Playlist(
          id: 'p1',
          name: 'Server Mix',
          source: PlaylistSource.jellyfin,
          remoteId: 'srv-1',
          trackIds: <String>['101', '202'],
          syncState: PlaylistSyncState.synced,
        ),
      ]);
      final SyncedPlaylistRepository repository = build();

      final Playlist? migrated = await repository.getPlaylistById('p1');
      expect(migrated!.trackIds, <String>['jellyfin:101', 'jellyfin:202']);
    });

    test('resolves a local playlist\'s bare remote id against the catalog',
        () async {
      await store.save(<Playlist>[
        const Playlist(
          id: 'p1',
          name: 'Local Mix',
          // A local path (already a uri) and a bare remote id from adding a
          // streamed track to a local playlist.
          trackIds: <String>['/music/song.mp3', '101'],
        ),
      ]);
      // The catalog exposes id 101 under a single provider → safe to attribute.
      final SyncedPlaylistRepository repository = build(
        catalog: () async => const <Track>[
          Track(id: '/music/song.mp3', title: 'Song', uri: '/music/song.mp3'),
          Track(id: '101', title: 'Alpha', uri: 'subsonic:101'),
        ],
      );

      final Playlist? migrated = await repository.getPlaylistById('p1');
      expect(migrated!.trackIds, <String>['/music/song.mp3', 'subsonic:101']);
    });

    test('leaves an ambiguous local bare id untouched (never guesses)',
        () async {
      await store.save(<Playlist>[
        const Playlist(id: 'p1', name: 'Local Mix', trackIds: <String>['101']),
      ]);
      // Two providers expose id 101 → the entry can't be safely attributed.
      final SyncedPlaylistRepository repository = build(
        catalog: () async => const <Track>[
          Track(id: '101', title: 'Alpha', uri: 'jellyfin:101'),
          Track(id: '101', title: 'Beta', uri: 'subsonic:101'),
        ],
      );

      final Playlist? migrated = await repository.getPlaylistById('p1');
      expect(migrated!.trackIds, <String>['101']); // preserved, not mis-keyed
    });
  });

  group('SyncedPlaylistRepository (Subsonic sync)', () {
    late InMemoryPlaylistStore store;
    late FakeSubsonicClient client;
    late SyncedPlaylistRepository repository;
    late int counter;

    setUp(() {
      store = InMemoryPlaylistStore();
      client = FakeSubsonicClient();
      counter = 0;
      repository = SyncedPlaylistRepository(
        store: store,
        gateways: <RemotePlaylistGateway>[
          SubsonicPlaylistGateway(
            client: client,
            session: () => _subsonicSession,
          ),
        ],
        idGenerator: () => 'pl-${counter++}',
        now: () => DateTime(2024, 1, 1),
      );
    });

    test('creates a Navidrome playlist and records the server id', () async {
      client.createdPlaylistId = 'p-9';
      final Playlist created = await repository.createPlaylist(
        'Server Mix',
        source: PlaylistSource.subsonic,
      );
      expect(client.createCalls.single.name, 'Server Mix');
      expect(created.source, PlaylistSource.subsonic);
      expect(created.remoteId, 'p-9');
      expect(created.syncState, PlaylistSyncState.synced);
    });

    test('membership changes replace the full ordered song list', () async {
      client.createdPlaylistId = 'p-1';
      final Playlist created = await repository.createPlaylist(
        'Mix',
        source: PlaylistSource.subsonic,
      );
      await repository.addTracks(
        created.id,
        <String>['subsonic:a', 'subsonic:b'],
      );
      // The server received a full ordered replace (add covers reorder too).
      expect(client.setSongsCalls.last.playlistId, 'p-1');
      expect(client.setSongsCalls.last.songIds, <String>['a', 'b']);

      await repository.removeTrack(created.id, 'subsonic:a');
      expect(client.setSongsCalls.last.songIds, <String>['b']);
    });

    test('reordering pushes the new order to the server', () async {
      client.createdPlaylistId = 'p-1';
      final Playlist created = await repository.createPlaylist(
        'Mix',
        source: PlaylistSource.subsonic,
      );
      await repository.addTracks(
        created.id,
        <String>['subsonic:a', 'subsonic:b', 'subsonic:c'],
      );
      // Move 'a' (0) to the end.
      await repository.reorderTracks(created.id, 0, 3);
      expect(client.setSongsCalls.last.songIds, <String>['b', 'c', 'a']);
    });

    test('renaming a synced playlist pushes to the server', () async {
      client.createdPlaylistId = 'p-1';
      final Playlist created = await repository.createPlaylist(
        'Old',
        source: PlaylistSource.subsonic,
      );
      await repository.renamePlaylist(created.id, 'New');
      expect(client.renameCalls.single, (playlistId: 'p-1', name: 'New'));
      final Playlist? updated = await repository.getPlaylistById(created.id);
      expect(updated!.name, 'New');
      expect(updated.syncState, PlaylistSyncState.synced);
    });

    test('deleting a synced playlist deletes it on the server', () async {
      client.createdPlaylistId = 'p-3';
      final Playlist created = await repository.createPlaylist(
        'Mix',
        source: PlaylistSource.subsonic,
      );
      await repository.deletePlaylist(created.id);
      expect(client.deletedPlaylistIds, <String>['p-3']);
      expect(await repository.getAllPlaylists(), isEmpty);
    });

    test('deleting a local playlist never touches the server', () async {
      // Non-destructive guarantee: a local-only playlist delete makes no remote
      // call, so nothing can be removed from Navidrome by accident.
      final Playlist local = await repository.createPlaylist('Local Mix');
      await repository.deletePlaylist(local.id);
      expect(client.deletedPlaylistIds, isEmpty);
    });

    test('imports Navidrome playlists on refresh, order preserved', () async {
      client.playlists = <SubsonicPlaylistDto>[
        const SubsonicPlaylistDto(id: 'p-77', name: 'From Server'),
      ];
      client.playlistSongIds = <String, List<String>>{
        'p-77': <String>['c', 'a', 'b'],
      };

      final PlaylistSyncResult result = await repository.refreshFromRemote();

      expect(result.didSync, isTrue);
      expect(result.playlistCount, 1);
      final List<Playlist> all = await repository.getAllPlaylists();
      expect(all.single.name, 'From Server');
      expect(all.single.remoteId, 'p-77');
      expect(all.single.source, PlaylistSource.subsonic);
      // Server song ids are namespaced to subsonic: uris, order preserved.
      expect(all.single.trackIds,
          <String>['subsonic:c', 'subsonic:a', 'subsonic:b']);
    });

    test('repeated refresh does not duplicate the imported playlist', () async {
      client.playlists = <SubsonicPlaylistDto>[
        const SubsonicPlaylistDto(id: 'p-1', name: 'Mix'),
      ];
      client.playlistSongIds = <String, List<String>>{
        'p-1': <String>['a'],
      };
      await repository.refreshFromRemote();
      await repository.refreshFromRemote();
      final List<Playlist> all = await repository.getAllPlaylists();
      expect(all.where((Playlist p) => p.remoteId == 'p-1'), hasLength(1));
    });

    test('a failed membership push flags syncFailed without throwing',
        () async {
      client.createdPlaylistId = 'p-2';
      final Playlist created = await repository.createPlaylist(
        'Mix',
        source: PlaylistSource.subsonic,
      );
      client.playlistError = SubsonicException.notReachable();
      await repository.addTrack(created.id, 'subsonic:a');
      final Playlist? updated = await repository.getPlaylistById(created.id);
      // The local add still stands, but the sync state is honest.
      expect(updated!.trackIds, contains('subsonic:a'));
      expect(updated.syncState, PlaylistSyncState.syncFailed);
    });

    test('a Subsonic playlist deleted on the server is dropped on refresh',
        () async {
      client.playlists = <SubsonicPlaylistDto>[
        const SubsonicPlaylistDto(id: 'p-1', name: 'Mix'),
      ];
      client.playlistSongIds = <String, List<String>>{
        'p-1': <String>['a'],
      };
      await repository.refreshFromRemote();
      expect(await repository.getAllPlaylists(), hasLength(1));

      client.playlists = <SubsonicPlaylistDto>[];
      client.playlistSongIds = <String, List<String>>{};
      await repository.refreshFromRemote();
      expect(await repository.getAllPlaylists(), isEmpty);
    });
  });

  group('SyncedPlaylistRepository (multi-provider refresh)', () {
    test('refresh keeps each provider\'s playlists scoped to its own server',
        () async {
      final store = InMemoryPlaylistStore();
      final jellyfin = FakeJellyfinClient();
      final subsonic = FakeSubsonicClient();
      int counter = 0;
      final repository = SyncedPlaylistRepository(
        store: store,
        gateways: <RemotePlaylistGateway>[
          JellyfinPlaylistGateway(client: jellyfin, session: () => _session),
          SubsonicPlaylistGateway(
            client: subsonic,
            session: () => _subsonicSession,
          ),
        ],
        idGenerator: () => 'pl-${counter++}',
        now: () => DateTime(2024, 1, 1),
      );

      jellyfin.playlists = const <JellyfinPlaylistDto>[
        JellyfinPlaylistDto(id: 'j-1', name: 'Jelly Mix'),
      ];
      jellyfin.playlistEntries['j-1'] = const <JellyfinPlaylistEntry>[
        JellyfinPlaylistEntry(itemId: 'a', playlistItemId: 'e-a'),
      ];
      subsonic.playlists = <SubsonicPlaylistDto>[
        const SubsonicPlaylistDto(id: 's-1', name: 'Nav Mix'),
      ];
      subsonic.playlistSongIds = <String, List<String>>{
        's-1': <String>['x'],
      };

      final PlaylistSyncResult result = await repository.refreshFromRemote();

      expect(result.didSync, isTrue);
      expect(result.playlistCount, 2);
      final List<Playlist> all = await repository.getAllPlaylists();
      final Playlist jelly =
          all.firstWhere((Playlist p) => p.source == PlaylistSource.jellyfin);
      final Playlist nav =
          all.firstWhere((Playlist p) => p.source == PlaylistSource.subsonic);
      expect(jelly.trackIds, <String>['jellyfin:a']);
      expect(nav.trackIds, <String>['subsonic:x']);

      // The Subsonic server drops its playlist; the Jellyfin one must survive.
      subsonic.playlists = <SubsonicPlaylistDto>[];
      subsonic.playlistSongIds = <String, List<String>>{};
      await repository.refreshFromRemote();
      final List<Playlist> after = await repository.getAllPlaylists();
      expect(after, hasLength(1));
      expect(after.single.source, PlaylistSource.jellyfin);
    });
  });

  // A refresh waits on the network (1 + N requests per provider), and the user
  // keeps editing meanwhile: opening the Playlists tab starts one, then "New
  // playlist" is right there. Whatever lands must be folded into the playlists
  // as they are when the server answers, never written over them.
  group('SyncedPlaylistRepository (edits during an in-flight refresh)', () {
    late _CountingPlaylistStore store;
    late _GatedPlaylistGateway gateway;
    late SyncedPlaylistRepository repository;
    late int counter;

    setUp(() {
      store = _CountingPlaylistStore();
      gateway = _GatedPlaylistGateway(PlaylistSource.subsonic)
        ..server = <RemotePlaylistData>[
          const RemotePlaylistData(
            remoteId: 'srv-1',
            name: 'Server Mix',
            trackUris: <String>['subsonic:a'],
          ),
        ];
      counter = 0;
      repository = SyncedPlaylistRepository(
        store: store,
        gateways: <RemotePlaylistGateway>[gateway],
        idGenerator: () => 'pl-${counter++}',
        now: () => DateTime(2024, 1, 1),
      );
    });

    /// Runs a refresh whose fetch is held until [during] has finished, the way
    /// a slow server leaves the user time to edit before it answers.
    Future<PlaylistSyncResult> refreshAround(
      Future<void> Function() during,
    ) async {
      gateway.hold();
      final Future<PlaylistSyncResult> refresh = repository.refreshFromRemote();
      await gateway.fetchStarted;
      await during();
      gateway.release();
      return refresh;
    }

    Future<List<String>> names() async => <String>[
          for (final Playlist p in await repository.getAllPlaylists()) p.name,
        ];

    Future<List<String>> storedNames() async => <String>[
          for (final Playlist p in await store.load()) p.name,
        ];

    test('a playlist created during a refresh survives it', () async {
      await refreshAround(() => repository.createPlaylist('Road trip'));

      expect(
          await names(), unorderedEquals(<String>['Server Mix', 'Road trip']));
      expect(
        await storedNames(),
        unorderedEquals(<String>['Server Mix', 'Road trip']),
      );
    });

    test('a local playlist deleted during a refresh stays deleted', () async {
      final Playlist doomed = await repository.createPlaylist('Old mix');

      await refreshAround(() => repository.deletePlaylist(doomed.id));

      expect(await repository.getPlaylistById(doomed.id), isNull);
      expect(await storedNames(), <String>['Server Mix']);
    });

    test('edits to a local playlist during a refresh survive it', () async {
      final Playlist mix = await repository.createPlaylist('Mix');
      await repository.addTracks(mix.id, <String>['a', 'b', 'c']);

      await refreshAround(() async {
        await repository.addTrack(mix.id, 'd');
        await repository.renamePlaylist(mix.id, 'Renamed');
        await repository.reorderTracks(mix.id, 0, 4); // 'a' to the end
      });

      final Playlist? after = await repository.getPlaylistById(mix.id);
      expect(after!.name, 'Renamed');
      expect(after.trackIds, <String>['b', 'c', 'd', 'a']);
      final Playlist stored =
          (await store.load()).singleWhere((Playlist p) => p.id == mix.id);
      expect(stored.name, 'Renamed');
      expect(stored.trackIds, <String>['b', 'c', 'd', 'a']);
    });

    test('the server still wins for synced playlists nobody edited', () async {
      gateway.server = <RemotePlaylistData>[
        const RemotePlaylistData(
          remoteId: 'srv-keep',
          name: 'Keep',
          trackUris: <String>['subsonic:a'],
        ),
        const RemotePlaylistData(
          remoteId: 'srv-gone',
          name: 'Gone',
          trackUris: <String>['subsonic:b'],
        ),
      ];
      await repository.refreshFromRemote();
      // Changed on the server from another client: renamed + re-membered,
      // deleted, and created.
      gateway.server = <RemotePlaylistData>[
        const RemotePlaylistData(
          remoteId: 'srv-keep',
          name: 'Kept',
          trackUris: <String>['subsonic:a', 'subsonic:c'],
        ),
        const RemotePlaylistData(
          remoteId: 'srv-new',
          name: 'New',
          trackUris: <String>['subsonic:d'],
        ),
      ];

      await refreshAround(() => repository.createPlaylist('Road trip'));

      for (final List<Playlist> all in <List<Playlist>>[
        await repository.getAllPlaylists(),
        await store.load(),
      ]) {
        final Playlist kept =
            all.singleWhere((Playlist p) => p.remoteId == 'srv-keep');
        expect(kept.name, 'Kept');
        expect(kept.trackIds, <String>['subsonic:a', 'subsonic:c']);
        expect(kept.syncState, PlaylistSyncState.synced);
        expect(all.where((Playlist p) => p.remoteId == 'srv-gone'), isEmpty);
        expect(
          all.singleWhere((Playlist p) => p.remoteId == 'srv-new').name,
          'New',
        );
        expect(all.where((Playlist p) => p.name == 'Road trip'), hasLength(1));
      }
    });

    test('a synced playlist edited during a refresh keeps the edit', () async {
      await repository.refreshFromRemote();
      final Playlist mix = (await repository.getAllPlaylists()).single;

      // The held fetch answered before the add reached the server, so its copy
      // is older than the edit and must not revert it.
      await refreshAround(() => repository.addTrack(mix.id, 'subsonic:b'));
      expect(
        (await repository.getPlaylistById(mix.id))!.trackIds,
        <String>['subsonic:a', 'subsonic:b'],
      );

      // The next refresh sees the pushed edit and agrees.
      await repository.refreshFromRemote();
      expect(
        (await repository.getPlaylistById(mix.id))!.trackIds,
        <String>['subsonic:a', 'subsonic:b'],
      );
    });

    test('a synced playlist deleted during a refresh is not brought back',
        () async {
      await repository.refreshFromRemote();
      final Playlist mix = (await repository.getAllPlaylists()).single;

      await refreshAround(() => repository.deletePlaylist(mix.id));

      expect(gateway.deletedRemoteIds, <String>['srv-1']);
      expect(await repository.getAllPlaylists(), isEmpty);
      expect(await store.load(), isEmpty);
    });

    test('a synced playlist created during a refresh is not dropped', () async {
      // The held fetch answers from before the create, so it doesn't list it.
      await refreshAround(
        () => repository.createPlaylist(
          'Road trip',
          source: PlaylistSource.subsonic,
        ),
      );

      for (final List<Playlist> all in <List<Playlist>>[
        await repository.getAllPlaylists(),
        await store.load(),
      ]) {
        final Playlist trip =
            all.singleWhere((Playlist p) => p.name == 'Road trip');
        expect(trip.remoteId, 'srv-new-0');
        expect(trip.syncState, PlaylistSyncState.synced);
      }
    });

    test('signing out during a refresh keeps that provider cleared', () async {
      await repository.refreshFromRemote();
      final Playlist local = await repository.createPlaylist('Local Mix');
      gateway.server = <RemotePlaylistData>[
        ...gateway.server,
        const RemotePlaylistData(
          remoteId: 'srv-2',
          name: 'Another',
          trackUris: <String>['subsonic:z'],
        ),
      ];

      // The gateway stays "connected": the Subsonic one keeps using the session
      // it captured before sign-out, so only the clear itself can say so.
      await refreshAround(
        () => repository.clearRemote(source: PlaylistSource.subsonic),
      );

      for (final List<Playlist> all in <List<Playlist>>[
        await repository.getAllPlaylists(),
        await store.load(),
      ]) {
        expect(all, hasLength(1));
        expect(all.single.id, local.id);
      }
    });

    test('a provider that disconnects during a refresh is not imported',
        () async {
      final PlaylistSyncResult result = await refreshAround(() async {
        gateway.connected = false;
      });

      expect(result.outcome, RemoteSyncOutcome.notConfigured);
      expect(await repository.getAllPlaylists(), isEmpty);
      expect(await store.load(), isEmpty);
    });

    test('a refresh that changes nothing does not rewrite the store', () async {
      await repository.refreshFromRemote();
      final int saves = store.saves;
      final Playlist before = (await repository.getAllPlaylists()).single;

      final PlaylistSyncResult result = await repository.refreshFromRemote();

      expect(result.didSync, isTrue);
      expect(result.playlistCount, 1);
      expect(store.saves, saves);
      expect(
        (await repository.getAllPlaylists()).single,
        same(before),
      );
    });

    test('overlapping refreshes share one fetch', () async {
      gateway.hold();
      final Future<PlaylistSyncResult> first = repository.refreshFromRemote();
      await gateway.fetchStarted;
      final Future<PlaylistSyncResult> second = repository.refreshFromRemote();
      await pumpEventQueue();
      gateway.release();

      final List<PlaylistSyncResult> results =
          await Future.wait(<Future<PlaylistSyncResult>>[first, second]);

      expect(gateway.fetchCount, 1);
      for (final PlaylistSyncResult result in results) {
        expect(result.didSync, isTrue);
        expect(result.playlistCount, 1);
      }
      expect(await repository.getAllPlaylists(), hasLength(1));
    });

    test('a provider connected after a refresh started gets its own fetch',
        () async {
      final _GatedPlaylistGateway jellyfin =
          _GatedPlaylistGateway(PlaylistSource.jellyfin)
            ..server = <RemotePlaylistData>[
              const RemotePlaylistData(
                remoteId: 'j-1',
                name: 'Jelly Mix',
                trackUris: <String>['jellyfin:a'],
              ),
            ];
      gateway.connected = false;
      repository = SyncedPlaylistRepository(
        store: store,
        gateways: <RemotePlaylistGateway>[jellyfin, gateway],
        idGenerator: () => 'pl-${counter++}',
        now: () => DateTime(2024, 1, 1),
      );

      jellyfin.hold();
      final Future<PlaylistSyncResult> first = repository.refreshFromRemote();
      await jellyfin.fetchStarted;
      // Signing in to Navidrome now: the refresh in flight never asked it.
      gateway.connected = true;
      final Future<PlaylistSyncResult> second = repository.refreshFromRemote();
      await pumpEventQueue();
      jellyfin.release();
      await first;
      final PlaylistSyncResult result = await second;

      expect(gateway.fetchCount, 1);
      expect(result.playlistCount, 2);
      expect(
        <String>[
          for (final Playlist p in await repository.getAllPlaylists()) p.name,
        ],
        unorderedEquals(<String>['Jelly Mix', 'Server Mix']),
      );
    });

    test(
        'a refresh for a newly connected provider still applies its newer answer',
        () async {
      final _GatedPlaylistGateway jellyfin =
          _GatedPlaylistGateway(PlaylistSource.jellyfin)
            ..server = <RemotePlaylistData>[
              const RemotePlaylistData(
                remoteId: 'j-1',
                name: 'One',
                trackUris: <String>['jellyfin:a'],
              ),
              const RemotePlaylistData(
                remoteId: 'j-2',
                name: 'Two',
                trackUris: <String>['jellyfin:b'],
              ),
            ];
      gateway.connected = false;
      repository = SyncedPlaylistRepository(
        store: store,
        gateways: <RemotePlaylistGateway>[jellyfin, gateway],
        idGenerator: () => 'pl-${counter++}',
        now: () => DateTime(2024, 1, 1),
      );
      await repository.refreshFromRemote();

      // Changed from another client, twice: the first refresh reads the first
      // change, then the second change lands before the next refresh asks.
      jellyfin.server = <RemotePlaylistData>[
        const RemotePlaylistData(
          remoteId: 'j-1',
          name: 'One, renamed',
          trackUris: <String>['jellyfin:a'],
        ),
        const RemotePlaylistData(
          remoteId: 'j-2',
          name: 'Two, renamed',
          trackUris: <String>['jellyfin:b'],
        ),
      ];
      jellyfin.hold();
      final Future<PlaylistSyncResult> first = repository.refreshFromRemote();
      await jellyfin.fetchStarted;
      jellyfin.server = <RemotePlaylistData>[
        const RemotePlaylistData(
          remoteId: 'j-1',
          name: 'One, renamed again',
          trackUris: <String>['jellyfin:a', 'jellyfin:c'],
        ),
      ];
      // Signing in to Navidrome now starts a refresh the first can't serve.
      gateway.connected = true;
      final Future<PlaylistSyncResult> second = repository.refreshFromRemote();
      await pumpEventQueue();
      jellyfin.release();
      await first;
      await second;

      // The first refresh's merge is not an edit by the user: the second,
      // newer, answer applies over it, deletion included.
      for (final List<Playlist> all in <List<Playlist>>[
        await repository.getAllPlaylists(),
        await store.load(),
      ]) {
        final Playlist one =
            all.singleWhere((Playlist p) => p.remoteId == 'j-1');
        expect(one.name, 'One, renamed again');
        expect(one.trackIds, <String>['jellyfin:a', 'jellyfin:c']);
        expect(all.where((Playlist p) => p.remoteId == 'j-2'), isEmpty);
        expect(all.where((Playlist p) => p.name == 'Server Mix'), hasLength(1));
      }
    });

    test('an older answer landing after a newer one does not undo it',
        () async {
      final _GatedPlaylistGateway jellyfin =
          _GatedPlaylistGateway(PlaylistSource.jellyfin)
            ..server = <RemotePlaylistData>[
              const RemotePlaylistData(
                remoteId: 'j-1',
                name: 'One',
                trackUris: <String>['jellyfin:a'],
              ),
              const RemotePlaylistData(
                remoteId: 'j-2',
                name: 'Two',
                trackUris: <String>['jellyfin:b'],
              ),
            ];
      gateway.connected = false;
      repository = SyncedPlaylistRepository(
        store: store,
        gateways: <RemotePlaylistGateway>[jellyfin, gateway],
        idGenerator: () => 'pl-${counter++}',
        now: () => DateTime(2024, 1, 1),
      );
      await repository.refreshFromRemote();

      jellyfin.server = <RemotePlaylistData>[
        const RemotePlaylistData(
          remoteId: 'j-1',
          name: 'One, renamed',
          trackUris: <String>['jellyfin:a'],
        ),
        const RemotePlaylistData(
          remoteId: 'j-2',
          name: 'Two, briefly',
          trackUris: <String>['jellyfin:b'],
        ),
      ];
      jellyfin.hold();
      final Future<PlaylistSyncResult> first = repository.refreshFromRemote();
      await jellyfin.fetchStarted;
      // Renamed again, and the brief rename undone, before the next request.
      jellyfin.server = <RemotePlaylistData>[
        const RemotePlaylistData(
          remoteId: 'j-1',
          name: 'One, renamed again',
          trackUris: <String>['jellyfin:a'],
        ),
        const RemotePlaylistData(
          remoteId: 'j-2',
          name: 'Two',
          trackUris: <String>['jellyfin:b'],
        ),
      ];
      gateway.connected = true;
      final Future<PlaylistSyncResult> second = repository.refreshFromRemote();
      await pumpEventQueue();
      expect(jellyfin.fetchCount, 3);

      // The newer answer lands first, then the older one.
      jellyfin.releaseOne(1);
      await second;
      jellyfin.release();
      await first;

      for (final List<Playlist> all in <List<Playlist>>[
        await repository.getAllPlaylists(),
        await store.load(),
      ]) {
        expect(
          all.singleWhere((Playlist p) => p.remoteId == 'j-1').name,
          'One, renamed again',
        );
        expect(
          all.singleWhere((Playlist p) => p.remoteId == 'j-2').name,
          'Two',
          reason: 'the newer answer left it as it was, and that still counts',
        );
      }
    });

    test('a refresh after a provider signs out does not wait on it', () async {
      final _GatedPlaylistGateway jellyfin =
          _GatedPlaylistGateway(PlaylistSource.jellyfin)
            ..server = <RemotePlaylistData>[
              const RemotePlaylistData(
                remoteId: 'j-1',
                name: 'Jelly Mix',
                trackUris: <String>['jellyfin:a'],
              ),
            ];
      repository = SyncedPlaylistRepository(
        store: store,
        gateways: <RemotePlaylistGateway>[jellyfin, gateway],
        idGenerator: () => 'pl-${counter++}',
        now: () => DateTime(2024, 1, 1),
      );

      gateway.hold();
      final Future<PlaylistSyncResult> first = repository.refreshFromRemote();
      await gateway.fetchStarted;
      // Signed out of Navidrome while its request is still out, maybe to a
      // server that will only time out.
      gateway.connected = false;
      await repository.clearRemote(source: PlaylistSource.subsonic);
      PlaylistSyncResult? result;
      unawaited(
        repository.refreshFromRemote().then((PlaylistSyncResult r) {
          result = r;
        }),
      );
      await pumpEventQueue();

      expect(result, isNotNull, reason: 'it did not wait for Navidrome');
      expect(result!.playlistCount, 1);
      expect(jellyfin.fetchCount, 2);
      expect(gateway.fetchCount, 1);

      gateway.release();
      await first;
      expect(
        <String>[
          for (final Playlist p in await repository.getAllPlaylists()) p.name,
        ],
        <String>['Jelly Mix'],
      );
    });
  });
}

/// An [InMemoryPlaylistStore] that counts writes, so a test can tell a no-op
/// refresh from one that rewrote the store.
class _CountingPlaylistStore extends InMemoryPlaylistStore {
  int saves = 0;

  @override
  Future<void> save(List<Playlist> playlists) {
    saves++;
    return super.save(playlists);
  }
}

/// A [RemotePlaylistGateway] whose [fetchPlaylists] can be held mid-flight, so
/// a test can edit playlists while a refresh waits on the network. The server
/// list is read when the fetch starts, like a server that answered before the
/// edit reached it; pushes update it, so a later fetch sees them.
class _GatedPlaylistGateway implements RemotePlaylistGateway {
  _GatedPlaylistGateway(this.source);

  @override
  final PlaylistSource source;

  bool connected = true;
  List<RemotePlaylistData> server = <RemotePlaylistData>[];
  int fetchCount = 0;
  final List<String> deletedRemoteIds = <String>[];
  int _created = 0;

  bool _holding = false;
  final List<Completer<void>> _held = <Completer<void>>[];
  Completer<void> _fetchStarted = Completer<void>();

  /// Holds every fetch from now until [release].
  void hold() {
    _holding = true;
    _fetchStarted = Completer<void>();
  }

  /// Completes once a fetch has read the server list (and, if held, is
  /// waiting for [release]).
  Future<void> get fetchStarted => _fetchStarted.future;

  void release() {
    _holding = false;
    for (final Completer<void> held in _held) {
      if (!held.isCompleted) held.complete();
    }
    _held.clear();
  }

  /// Lets only the [index]th fetch held since [hold] answer.
  void releaseOne(int index) => _held[index].complete();

  @override
  bool get isConnected => connected;

  @override
  bool get pushesRename => true;

  @override
  bool get pushesReorder => true;

  @override
  Future<List<RemotePlaylistData>> fetchPlaylists() async {
    fetchCount++;
    final List<RemotePlaylistData> answer = List<RemotePlaylistData>.of(server);
    Completer<void>? gate;
    if (_holding) _held.add(gate = Completer<void>());
    if (!_fetchStarted.isCompleted) _fetchStarted.complete();
    if (gate != null) await gate.future;
    return answer;
  }

  @override
  Future<String> createRemotePlaylist(
    String name,
    List<String> trackUris,
  ) async {
    final String remoteId = 'srv-new-${_created++}';
    server = <RemotePlaylistData>[
      ...server,
      RemotePlaylistData(remoteId: remoteId, name: name, trackUris: trackUris),
    ];
    return remoteId;
  }

  @override
  Future<void> syncMembership(
    String remoteId, {
    required List<String> orderedTrackUris,
    required List<String> added,
    required List<String> removed,
  }) async {
    server = <RemotePlaylistData>[
      for (final RemotePlaylistData p in server)
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
    server = <RemotePlaylistData>[
      for (final RemotePlaylistData p in server)
        p.remoteId == remoteId
            ? RemotePlaylistData(
                remoteId: remoteId,
                name: name,
                trackUris: p.trackUris,
              )
            : p,
    ];
  }

  @override
  Future<void> deleteRemote(String remoteId) async {
    deletedRemoteIds.add(remoteId);
    server = <RemotePlaylistData>[
      for (final RemotePlaylistData p in server)
        if (p.remoteId != remoteId) p,
    ];
  }
}
