import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/music_library_repository.dart';
import 'package:linthra/core/repositories/remote_sync_gateway.dart';
import 'package:linthra/core/sources/subsonic/subsonic_account_fingerprint.dart';
import 'package:linthra/core/sources/subsonic/subsonic_api.dart';
import 'package:linthra/core/sources/subsonic/subsonic_exception.dart';
import 'package:linthra/data/repositories/favorites_repository_provider.dart';
import 'package:linthra/data/repositories/in_memory_favorites_store.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_auto_sync_store.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_session_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/data/repositories/subsonic_auto_sync_store_provider.dart';
import 'package:linthra/data/repositories/subsonic_favorites_gateway.dart';
import 'package:linthra/data/repositories/subsonic_playlist_gateway.dart';
import 'package:linthra/data/repositories/subsonic_session_store_provider.dart';
import 'package:linthra/data/repositories/synced_favorites_repository.dart';
import 'package:linthra/data/repositories/synced_playlist_repository.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_controller.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_providers.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_state.dart';
import 'package:linthra/features/settings/subsonic/subsonic_sync_controller.dart';
import 'package:linthra/features/settings/subsonic/subsonic_sync_state.dart';

import '../../../core/sources/subsonic/fake_subsonic_client.dart';

/// The session a sign-in to `music.example.com` as `alice` produces, for
/// computing the expected account fingerprint (which reads only baseUrl +
/// username; the credential fields are irrelevant to it).
SubsonicSession _sessionFor({
  String baseUrl = 'https://music.example.com',
  String username = 'alice',
}) =>
    SubsonicSession(
      baseUrl: baseUrl,
      username: username,
      salt: 'irrelevant',
      token: 'irrelevant',
    );

/// A fake client with one album of two songs, so a sync lands two tracks.
FakeSubsonicClient _clientWithLibrary() => FakeSubsonicClient(
      albums: const <SubsonicAlbumDto>[SubsonicAlbumDto(id: 'al', name: 'A')],
      songsByAlbum: const <String, List<SubsonicSongDto>>{
        'al': <SubsonicSongDto>[
          SubsonicSongDto(id: 's1', title: 'One'),
          SubsonicSongDto(id: 's2', title: 'Two'),
        ],
      },
    );

class _RecordingRepository implements MusicLibraryRepository {
  int upsertCount = 0;
  String? lastSourceId;
  List<Track> lastTracks = const <Track>[];

  @override
  Future<void> upsertCatalog({
    required String sourceId,
    required List<Track> tracks,
    required List<Album> albums,
    required List<Artist> artists,
  }) async {
    upsertCount++;
    lastSourceId = sourceId;
    lastTracks = tracks;
  }

  @override
  Future<List<Track>> getAllTracks() async => lastTracks;

  @override
  Future<List<Album>> getAllAlbums() async => const <Album>[];

  @override
  Future<List<Artist>> getAllArtists() async => const <Artist>[];

  @override
  Future<Track?> getTrackByUri(String uri) async => null;

  @override
  Future<void> removeTracks(List<String> trackIds) async {}
}

ProviderContainer _container({
  required FakeSubsonicClient client,
  required _RecordingRepository repository,
  InMemorySubsonicAutoSyncStore? autoSyncStore,
  SyncedPlaylistRepository? playlists,
  SyncedFavoritesRepository? favorites,
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      subsonicClientProvider.overrideWithValue(client),
      subsonicSessionStoreProvider
          .overrideWithValue(InMemorySubsonicSessionStore()),
      subsonicAutoSyncStoreProvider
          .overrideWithValue(autoSyncStore ?? InMemorySubsonicAutoSyncStore()),
      musicLibraryRepositoryProvider.overrideWithValue(repository),
      if (playlists != null)
        playlistRepositoryProvider.overrideWithValue(playlists),
      if (favorites != null)
        favoritesRepositoryProvider.overrideWithValue(favorites),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Lets the controller's async load settle.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

/// Drains the fire-and-forget auto-sync started by sign-in to completion.
Future<void> _drainAutoSync() => pumpEventQueue(times: 50);

Future<bool> _signIn(
  ProviderContainer container, {
  String url = 'music.example.com',
  String username = 'alice',
}) =>
    container.read(subsonicSettingsControllerProvider.notifier).signIn(
          url: url,
          username: username,
          password: 'pw',
        );

void main() {
  group('Subsonic/Navidrome auto-sync on connect', () {
    test('a successful sign-in triggers exactly one auto-sync', () async {
      final repo = _RecordingRepository();
      final store = InMemorySubsonicAutoSyncStore();
      final container = _container(
        client: _clientWithLibrary(),
        repository: repo,
        autoSyncStore: store,
      );
      container.read(subsonicSettingsControllerProvider);
      await _settle();

      expect(await _signIn(container), isTrue);
      await _drainAutoSync();

      // One sync ran down the normal upsert path…
      expect(repo.upsertCount, 1);
      expect(repo.lastSourceId, 'subsonic');
      expect(repo.lastTracks, hasLength(2));
      // …and finished as a success the UI can show.
      expect(
        container.read(subsonicSyncControllerProvider).status,
        SubsonicSyncStatus.success,
      );
      // The account is now remembered so it won't auto-sync again on its own.
      expect(await store.read(), subsonicAccountFingerprint(_sessionFor()));
    });

    test('the initial auto-sync also imports playlists and favourites',
        () async {
      final client = _clientWithLibrary()
        ..playlists = <SubsonicPlaylistDto>[
          const SubsonicPlaylistDto(id: 'p-1', name: 'Road Trip'),
        ]
        ..playlistSongIds = <String, List<String>>{
          'p-1': <String>['s1'],
        }
        ..starredSongIds = <String>{'s2'};

      // Gateway-backed repos over the same fake client, reading the live
      // session lazily — exactly how production wires them.
      late ProviderContainer container;
      SubsonicSession? session() =>
          container.read(subsonicSettingsControllerProvider.notifier).session;
      final playlistRepo = SyncedPlaylistRepository(
        store: InMemoryPlaylistStore(),
        gateways: <RemotePlaylistGateway>[
          SubsonicPlaylistGateway(client: client, session: session),
        ],
      );
      addTearDown(playlistRepo.dispose);
      final favoritesRepo = SyncedFavoritesRepository(
        store: InMemoryFavoritesStore(),
        gateways: <RemoteFavoritesGateway>[
          SubsonicFavoritesGateway(client: client, session: session),
        ],
      );
      addTearDown(favoritesRepo.dispose);
      container = _container(
        client: client,
        repository: _RecordingRepository(),
        playlists: playlistRepo,
        favorites: favoritesRepo,
      );
      container.read(subsonicSettingsControllerProvider);
      await _settle();

      expect(await _signIn(container), isTrue);
      await _drainAutoSync();

      // The one automatic sync brought tracks, the playlist, and the heart.
      final state = container.read(subsonicSyncControllerProvider);
      expect(state.status, SubsonicSyncStatus.success);
      expect(state.trackCount, 2);
      expect(state.playlistCount, 1);
      expect(state.favoriteCount, 1);
      final imported = await playlistRepo.getAllPlaylists();
      expect(imported.single.source, PlaylistSource.subsonic);
      expect(imported.single.trackIds, <String>['subsonic:s1']);
      expect(favoritesRepo.isFavorite('subsonic:s2'), isTrue);
    });

    test('a failed sign-in does not trigger a sync', () async {
      final repo = _RecordingRepository();
      final store = InMemorySubsonicAutoSyncStore();
      final container = _container(
        client: FakeSubsonicClient(
          pingError: SubsonicException.unauthorized(),
        ),
        repository: repo,
        autoSyncStore: store,
      );
      container.read(subsonicSettingsControllerProvider);
      await _settle();

      expect(await _signIn(container), isFalse);
      await _drainAutoSync();

      expect(repo.upsertCount, 0);
      expect(
        container.read(subsonicSyncControllerProvider).status,
        SubsonicSyncStatus.idle,
      );
      expect(await store.read(), isNull);
    });

    test('reconnecting the same account does not auto-sync again', () async {
      final repo = _RecordingRepository();
      // The store already remembers this exact account from a prior run.
      final store = InMemorySubsonicAutoSyncStore(
        subsonicAccountFingerprint(_sessionFor()),
      );
      final container = _container(
        client: _clientWithLibrary(),
        repository: repo,
        autoSyncStore: store,
      );
      container.read(subsonicSettingsControllerProvider);
      await _settle();

      expect(await _signIn(container), isTrue);
      await _drainAutoSync();

      // Connected, but no unsolicited full re-sync — the manual button remains.
      expect(repo.upsertCount, 0);
      expect(
        container.read(subsonicSyncControllerProvider).status,
        SubsonicSyncStatus.idle,
      );
    });

    test('changing server/account allows a new initial auto-sync', () async {
      final repo = _RecordingRepository();
      final store = InMemorySubsonicAutoSyncStore();
      final container = _container(
        client: _clientWithLibrary(),
        repository: repo,
        autoSyncStore: store,
      );
      container.read(subsonicSettingsControllerProvider);
      await _settle();

      // First account.
      await _signIn(container);
      await _drainAutoSync();
      expect(repo.upsertCount, 1);

      // Sign out, then sign in to a *different* server + user.
      await container.read(subsonicSettingsControllerProvider.notifier).clear();
      await _signIn(container, url: 'other.example.com', username: 'bob');
      await _drainAutoSync();

      // The new account is a fresh connection, so it auto-syncs once more.
      expect(repo.upsertCount, 2);
      expect(
        await store.read(),
        subsonicAccountFingerprint(
          _sessionFor(baseUrl: 'https://other.example.com', username: 'bob'),
        ),
      );
    });

    test('manual sync still works after the auto-sync', () async {
      final repo = _RecordingRepository();
      final container = _container(
        client: _clientWithLibrary(),
        repository: repo,
      );
      container.read(subsonicSettingsControllerProvider);
      await _settle();

      await _signIn(container);
      await _drainAutoSync();
      expect(repo.upsertCount, 1);

      // The user can still pull a refresh on demand.
      await container.read(subsonicSyncControllerProvider.notifier).sync();
      expect(repo.upsertCount, 2);
      expect(
        container.read(subsonicSyncControllerProvider).status,
        SubsonicSyncStatus.success,
      );
    });

    test('a sync failure after sign-in keeps the account connected to retry',
        () async {
      final repo = _RecordingRepository();
      final store = InMemorySubsonicAutoSyncStore();
      // Sign-in (ping) succeeds, but the library fetch fails — e.g. the server
      // became unreachable right after connecting.
      final container = _container(
        client: FakeSubsonicClient(
          listError: SubsonicException.notReachable(),
        ),
        repository: repo,
        autoSyncStore: store,
      );
      container.read(subsonicSettingsControllerProvider);
      await _settle();

      expect(await _signIn(container), isTrue);
      await _drainAutoSync();

      // Still connected; the sync errored calmly and nothing was wiped.
      expect(
        container.read(subsonicSettingsControllerProvider).phase,
        SubsonicConnectionPhase.connected,
      );
      final syncState = container.read(subsonicSyncControllerProvider);
      expect(syncState.status, SubsonicSyncStatus.error);
      expect(syncState.message, isNot(contains('tok')));
      expect(repo.upsertCount, 0);
      // The account is NOT recorded, so the next fresh connection retries —
      // and the manual sync stays available meanwhile.
      expect(await store.read(), isNull);
    });

    test('repeated provider rebuilds do not resync', () async {
      final repo = _RecordingRepository();
      final container = _container(
        client: _clientWithLibrary(),
        repository: repo,
      );
      container.read(subsonicSettingsControllerProvider);
      await _settle();
      await _signIn(container);
      await _drainAutoSync();
      expect(repo.upsertCount, 1);

      // Auto-sync lives in sign-in, not in any build(), so re-minting the
      // source (a connection-state change or a widget rebuild) never kicks off
      // another sync.
      for (int i = 0; i < 5; i++) {
        container.invalidate(subsonicMusicSourceProvider);
        container.read(subsonicMusicSourceProvider);
        container.read(subsonicSyncControllerProvider);
        await _drainAutoSync();
      }

      expect(repo.upsertCount, 1);
    });
  });
}
