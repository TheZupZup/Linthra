import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/playlist_store.dart';
import 'package:linthra/core/repositories/remote_sync_gateway.dart';
import 'package:linthra/core/services/song_origins.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/data/repositories/song_origins_provider.dart';
import 'package:linthra/data/repositories/synced_playlist_repository.dart';
import 'package:linthra/features/playlists/playlist_providers.dart';

import '../../support/fake_song_origins.dart';
import '../library/fake_music_library_repository.dart';

/// #795: a device playlist's Subsonic and Plex songs stay the songs of the
/// server they were added on.

Track _song(String uri, String title) => Track(id: uri, title: title, uri: uri);

/// Server A's song 48211 and server B's song with the same id.
final Track _onA = _song('subsonic:48211', 'Song on A');
final Track _onB = _song('subsonic:48211', 'Song on B');
final Track _jelly = _song('jellyfin:6f1c', 'Jellyfin song');

void main() {
  late FakeSongOrigins origins;
  late PlaylistStore store;
  late FakeMusicLibraryRepository library;

  setUp(() {
    origins = FakeSongOrigins(
      signedIn: <String, String?>{'subsonic:': 'server-a'},
      legacy: <String, String>{'subsonic:': 'server-a'},
    );
    addTearDown(origins.close);
    store = InMemoryPlaylistStore();
    library = FakeMusicLibraryRepository(tracks: <Track>[_onA, _jelly]);
  });

  SyncedPlaylistRepository repository() {
    final SyncedPlaylistRepository repo =
        SyncedPlaylistRepository(store: store, origins: origins);
    addTearDown(repo.dispose);
    return repo;
  }

  ProviderContainer app(SyncedPlaylistRepository repo) {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        playlistRepositoryProvider.overrideWithValue(repo),
        musicLibraryRepositoryProvider.overrideWithValue(library),
        songOriginsProvider.overrideWithValue(origins),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<PlaylistTracks> shown(ProviderContainer container, String id) async {
    // Listened to, as the screen does.
    container.listen(playlistByIdProvider(id), (_, __) {});
    container.listen(playlistTracksProvider(id), (_, __) {});
    await pumpEventQueue();
    return container.read(playlistTracksProvider(id).future);
  }

  /// Signs in to [server], whose library has [tracks].
  void switchTo(String? server, List<Track> tracks) {
    library = FakeMusicLibraryRepository(tracks: tracks);
    origins.signIn('subsonic:', server);
  }

  test(
      'a playlist made on server A never shows server B\'s song with the '
      'same id', () async {
    final SyncedPlaylistRepository repo = repository();
    final Playlist mix = await repo.createPlaylist('Mix');
    await repo.addTracks(mix.id, <String>['subsonic:48211', 'jellyfin:6f1c']);

    expect(
      (await repo.getPlaylistById(mix.id))!.entryOrigins,
      <String, String>{'subsonic:48211': 'server-a'},
    );
    PlaylistTracks tracks = await shown(app(repo), mix.id);
    expect(tracks.tracks.map((Track t) => t.title),
        <String>['Song on A', 'Jellyfin song']);

    // Signed in to B, whose song 48211 is something else.
    switchTo('server-b', <Track>[_onB, _jelly]);
    tracks = await shown(app(repo), mix.id);
    expect(tracks.tracks.map((Track t) => t.title), <String>['Jellyfin song']);
    expect(tracks.missingCount, 1);
    expect(repo.entriesHere((await repo.getPlaylistById(mix.id))!),
        <String>['jellyfin:6f1c']);

    // Back on A, after a restart too: the entry was never lost.
    switchTo('server-a', <Track>[_onA, _jelly]);
    final SyncedPlaylistRepository restarted = repository();
    tracks = await shown(app(restarted), mix.id);
    expect(tracks.tracks.map((Track t) => t.title),
        <String>['Song on A', 'Jellyfin song']);
    expect(tracks.missingCount, 0);
  });

  test('switching server re-resolves a playlist already on screen', () async {
    final SyncedPlaylistRepository repo = repository();
    final Playlist mix = await repo.createPlaylist('Mix');
    await repo.addTracks(mix.id, <String>['subsonic:48211']);
    final ProviderContainer container = app(repo);
    container.listen(playlistTracksProvider(mix.id), (_, __) {});
    expect((await shown(container, mix.id)).tracks, hasLength(1));

    // The library reads the same, but the account signed in changed.
    origins.signIn('subsonic:', 'server-b');
    await pumpEventQueue();
    final PlaylistTracks tracks =
        await container.read(playlistTracksProvider(mix.id).future);

    expect(tracks.tracks, isEmpty);
    expect(tracks.missingCount, 1);
  });

  test('the same id added on B while A\'s is listed does not replace A\'s',
      () async {
    final SyncedPlaylistRepository repo = repository();
    final Playlist mix = await repo.createPlaylist('Mix');
    await repo.addTracks(mix.id, <String>['subsonic:48211']);

    switchTo('server-b', <Track>[_onB]);
    await repo.addTracks(mix.id, <String>['subsonic:48211']);

    final Playlist kept = (await repo.getPlaylistById(mix.id))!;
    expect(kept.trackIds, <String>['subsonic:48211']);
    expect(kept.entryOrigins['subsonic:48211'], 'server-a');
  });

  test('removing a song drops what it recorded, undo records it again',
      () async {
    final SyncedPlaylistRepository repo = repository();
    final Playlist mix = await repo.createPlaylist('Mix');
    await repo.addTracks(mix.id, <String>['subsonic:48211', 'subsonic:7']);

    final List<int> at = await repo.removeTrack(mix.id, 'subsonic:48211');
    expect(
      (await repo.getPlaylistById(mix.id))!.entryOrigins,
      <String, String>{'subsonic:7': 'server-a'},
    );

    await repo.restoreTrack(mix.id, 'subsonic:48211', at);
    expect(
      (await repo.getPlaylistById(mix.id))!.entryOrigins['subsonic:48211'],
      'server-a',
    );
  });

  test('a song added while signed out belongs to no server', () async {
    switchTo(null, <Track>[_onA]);
    final SyncedPlaylistRepository repo = repository();
    final Playlist mix = await repo.createPlaylist('Mix');
    await repo.addTracks(mix.id, <String>['subsonic:48211']);

    expect(
      (await repo.getPlaylistById(mix.id))!.entryOrigins['subsonic:48211'],
      noSongOrigin,
    );
    for (final String server in <String>['server-a', 'server-b']) {
      switchTo(server, <Track>[_onA]);
      expect((await shown(app(repo), mix.id)).tracks, isEmpty);
    }
  });

  group('a playlist saved before origins were recorded', () {
    Future<SyncedPlaylistRepository> legacy() async {
      await store.save(const <Playlist>[
        Playlist(
          id: 'old',
          name: 'Old mix',
          trackIds: <String>['subsonic:48211', 'jellyfin:6f1c'],
        ),
      ]);
      return repository();
    }

    test('keeps its songs on the account it was settled to', () async {
      final SyncedPlaylistRepository repo = await legacy();
      expect((await shown(app(repo), 'old')).tracks, hasLength(2));
    });

    test('never gives them to another server', () async {
      final SyncedPlaylistRepository repo = await legacy();
      switchTo('server-b', <Track>[_onB, _jelly]);
      final PlaylistTracks tracks = await shown(app(repo), 'old');
      expect(
          tracks.tracks.map((Track t) => t.title), <String>['Jellyfin song']);
      expect(tracks.missingCount, 1);
    });

    test('settled to nobody, they never resolve', () async {
      origins.legacyOrigins['subsonic:'] = noSongOrigin;
      final SyncedPlaylistRepository repo = await legacy();
      expect((await shown(app(repo), 'old')).missingCount, 1);
    });
  });

  test('a synced playlist that becomes a device one keeps its account\'s songs',
      () async {
    final _Gateway gateway = _Gateway();
    final SyncedPlaylistRepository repo = SyncedPlaylistRepository(
      store: store,
      origins: origins,
      gateways: <RemotePlaylistGateway>[gateway],
    );
    addTearDown(repo.dispose);
    // Made while the server couldn't be reached: no server id.
    gateway.failCreates = true;
    final Playlist mix =
        await repo.createPlaylist('Mix', source: PlaylistSource.subsonic);
    await repo.addTracks(mix.id, <String>['subsonic:48211']);

    // Signing out makes it a device playlist.
    gateway.account = null;
    await repo.clearRemote(source: PlaylistSource.subsonic);
    final Playlist local = (await repo.getPlaylistById(mix.id))!;
    expect(local.source, PlaylistSource.local);
    expect(local.entryOrigins, <String, String>{'subsonic:48211': 'server-a'});

    switchTo('server-b', <Track>[_onB]);
    expect((await shown(app(repo), mix.id)).tracks, isEmpty);
  });
}

class _Gateway implements RemotePlaylistGateway {
  // The account key the gateway reports is the same origin a device
  // playlist's Subsonic entries record.
  String? account = 'server-a';
  bool failCreates = false;

  @override
  PlaylistSource get source => PlaylistSource.subsonic;
  @override
  bool get isConnected => account != null;
  @override
  String? get accountKey => account;
  @override
  bool get pushesRename => true;
  @override
  bool get pushesReorder => true;

  @override
  Future<RemotePlaylistListing> fetchPlaylists() async =>
      const RemotePlaylistListing(<RemotePlaylistData>[]);

  @override
  Future<String> createRemotePlaylist(
    String name,
    List<String> trackUris,
  ) async {
    if (failCreates) throw const RemoteSyncException('offline');
    return 'srv-1';
  }

  @override
  Future<void> syncMembership(
    String remoteId, {
    required List<String> orderedTrackUris,
    required List<String> added,
    required List<String> removed,
  }) async {}

  @override
  Future<void> renameRemote(String remoteId, String name) async {}

  @override
  Future<void> deleteRemote(String remoteId) async {}
}
