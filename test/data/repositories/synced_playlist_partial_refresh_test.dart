// One server failing doesn't cost the others their refresh, and a refresh
// for one server asks only that one.
//
// A listener signed in to both Jellyfin and Navidrome refreshes playlists
// from both at once. When one can't be reached, its synced playlists must be
// kept as they are (not read as deleted on the server), while the one that
// answered still brings in what changed there, and the refresh still says it
// synced. A refresh scoped to one server (signing in to it, or its own
// library sync ending) must ask only that server, and must not stand in for,
// or wait on, a refresh of every server that is still out.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/repositories/remote_sync_gateway.dart';
import 'package:linthra/core/repositories/remote_sync_result.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/core/sources/subsonic/subsonic_api.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/jellyfin_playlist_gateway.dart';
import 'package:linthra/data/repositories/subsonic_playlist_gateway.dart';
import 'package:linthra/data/repositories/synced_playlist_repository.dart';

import '../../core/sources/jellyfin/fake_jellyfin_client.dart';
import '../../core/sources/subsonic/fake_subsonic_client.dart';

const JellyfinSession _jellyfinSession = JellyfinSession(
  baseUrl: 'https://music.example.com',
  userId: 'user-1',
  accessToken: 'jellyfin-token',
  deviceId: 'device-1',
);

const SubsonicSession _subsonicSession = SubsonicSession(
  baseUrl: 'https://nav.example.com',
  username: 'alice',
  salt: 'salt1',
  token: 'tok1',
);

/// A Jellyfin server that counts how often its playlists were listed.
class _CountingJellyfinClient extends FakeJellyfinClient {
  int listings = 0;

  @override
  Future<List<JellyfinPlaylistDto>> fetchPlaylists(
    JellyfinSession session,
  ) {
    listings++;
    return super.fetchPlaylists(session);
  }
}

/// A Navidrome that counts how often its playlists were listed, and whose
/// listing can be held on the wire until the test lets it through.
class _GatedSubsonicClient extends FakeSubsonicClient {
  int listings = 0;
  Completer<void>? _hold;
  Completer<void> _listingStarted = Completer<void>();

  /// Holds every listing from now until [release].
  void hold() {
    _hold = Completer<void>();
    _listingStarted = Completer<void>();
  }

  void release() => _hold?.complete();

  /// Completes once a listing asked for since [hold] has reached the server.
  Future<void> get listingStarted => _listingStarted.future;

  @override
  Future<List<SubsonicPlaylistDto>> getPlaylists(
    SubsonicSession session,
  ) async {
    listings++;
    if (!_listingStarted.isCompleted) _listingStarted.complete();
    final Completer<void>? gate = _hold;
    if (gate != null) await gate.future;
    return super.getPlaylists(session);
  }
}

void main() {
  late InMemoryPlaylistStore store;
  late _CountingJellyfinClient jellyfin;
  late _GatedSubsonicClient subsonic;
  late SyncedPlaylistRepository repository;

  setUp(() async {
    store = InMemoryPlaylistStore();
    jellyfin = _CountingJellyfinClient()
      ..playlists = const <JellyfinPlaylistDto>[
        JellyfinPlaylistDto(id: 'j-1', name: 'Jelly Mix'),
      ];
    jellyfin.playlistEntries['j-1'] = const <JellyfinPlaylistEntry>[
      JellyfinPlaylistEntry(itemId: 'a', playlistItemId: 'e-a'),
    ];
    subsonic = _GatedSubsonicClient()
      ..playlists = <SubsonicPlaylistDto>[
        const SubsonicPlaylistDto(id: 's-1', name: 'Nav Mix'),
      ]
      ..playlistSongIds = <String, List<String>>{
        's-1': <String>['x'],
      };
    int counter = 0;
    repository = SyncedPlaylistRepository(
      store: store,
      gateways: <RemotePlaylistGateway>[
        JellyfinPlaylistGateway(
          client: jellyfin,
          session: () => _jellyfinSession,
        ),
        SubsonicPlaylistGateway(
          client: subsonic,
          session: () => _subsonicSession,
        ),
      ],
      idGenerator: () => 'pl-${counter++}',
      now: () => DateTime(2024, 1, 1),
    );
    // Both servers' playlists are on the device before each case starts.
    final PlaylistSyncResult first = await repository.refreshFromRemote();
    expect(first.playlistCount, 2);
  });

  /// Each synced playlist as `<server id>: <songs>`.
  Future<Map<String, List<String>>> synced() async => <String, List<String>>{
        for (final Playlist p in await repository.getAllPlaylists())
          if (p.remoteId != null) p.remoteId!: p.trackIds,
      };

  Future<Map<String, List<String>>> stored() async => <String, List<String>>{
        for (final Playlist p in await store.load())
          if (p.remoteId != null) p.remoteId!: p.trackIds,
      };

  test(
      'Jellyfin failing keeps its playlists while Navidrome brings in a new '
      'one', () async {
    jellyfin.playlistError = JellyfinException.notReachable();
    subsonic
      ..playlists = <SubsonicPlaylistDto>[
        const SubsonicPlaylistDto(id: 's-1', name: 'Nav Mix'),
        const SubsonicPlaylistDto(id: 's-2', name: 'Fresh on Nav'),
      ]
      ..playlistSongIds = <String, List<String>>{
        's-1': <String>['x'],
        's-2': <String>['y', 'z'],
      };

    final PlaylistSyncResult result = await repository.refreshFromRemote();

    // One server answered, so the refresh synced, counting what it listed.
    expect(result.didSync, isTrue);
    expect(result.playlistCount, 2);
    final Map<String, List<String>> expected = <String, List<String>>{
      'j-1': <String>['jellyfin:a'],
      's-1': <String>['subsonic:x'],
      's-2': <String>['subsonic:y', 'subsonic:z'],
    };
    expect(await synced(), expected);
    expect(await stored(), expected);
  });

  test('a refresh of Jellyfin alone that fails never asks Navidrome', () async {
    final int navidromeBefore = subsonic.listings;
    jellyfin.playlistError = JellyfinException.notReachable();

    final PlaylistSyncResult result =
        await repository.refreshFromRemote(source: PlaylistSource.jellyfin);

    expect(result.didFail, isTrue);
    expect(subsonic.listings, navidromeBefore);
    expect(await synced(), <String, List<String>>{
      'j-1': <String>['jellyfin:a'],
      's-1': <String>['subsonic:x'],
    });
  });

  test('a refresh of Navidrome alone syncs while Jellyfin is failing',
      () async {
    final int jellyfinBefore = jellyfin.listings;
    jellyfin.playlistError = JellyfinException.notReachable();
    subsonic.playlistSongIds = <String, List<String>>{
      's-1': <String>['x', 'w'],
    };

    final PlaylistSyncResult result =
        await repository.refreshFromRemote(source: PlaylistSource.subsonic);

    expect(result.didSync, isTrue);
    expect(result.playlistCount, 1);
    expect(jellyfin.listings, jellyfinBefore);
    expect(await synced(), <String, List<String>>{
      'j-1': <String>['jellyfin:a'],
      's-1': <String>['subsonic:x', 'subsonic:w'],
    });
  });

  test(
      'a refresh of Jellyfin alone does not join a refresh of every server '
      'still out', () async {
    final int jellyfinBefore = jellyfin.listings;
    // Navidrome's answer is still on the wire, so the refresh of both servers
    // is out, waiting on it.
    subsonic.hold();
    final Future<PlaylistSyncResult> everything =
        repository.refreshFromRemote();
    await subsonic.listingStarted;
    expect(jellyfin.listings, jellyfinBefore + 1);

    jellyfin.playlists = const <JellyfinPlaylistDto>[
      JellyfinPlaylistDto(id: 'j-1', name: 'Jelly Mix'),
      JellyfinPlaylistDto(id: 'j-2', name: 'Jelly New'),
    ];
    PlaylistSyncResult? scoped;
    unawaited(repository
        .refreshFromRemote(source: PlaylistSource.jellyfin)
        .then((PlaylistSyncResult r) => scoped = r));
    await pumpEventQueue();

    // It asked Jellyfin itself, and did not wait on Navidrome to answer.
    expect(jellyfin.listings, jellyfinBefore + 2);
    expect(scoped, isNotNull, reason: 'it waited on the refresh still out');
    expect(scoped!.didSync, isTrue);
    expect(scoped!.playlistCount, 2);
    expect((await synced()).keys, containsAll(<String>['j-1', 'j-2']));

    subsonic.release();
    final PlaylistSyncResult all = await everything;
    expect(all.didSync, isTrue);
    expect(subsonic.listings, 2);
  });
}
