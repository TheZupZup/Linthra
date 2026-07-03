import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/favorites_repository.dart';
import 'package:linthra/core/repositories/music_library_repository.dart';
import 'package:linthra/core/repositories/playlist_repository.dart';
import 'package:linthra/core/repositories/remote_sync_gateway.dart';
import 'package:linthra/core/sources/subsonic/subsonic_api.dart';
import 'package:linthra/core/sources/subsonic/subsonic_exception.dart';
import 'package:linthra/core/sources/subsonic/subsonic_music_source.dart';
import 'package:linthra/data/repositories/favorites_repository_provider.dart';
import 'package:linthra/data/repositories/in_memory_favorites_store.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/data/repositories/subsonic_favorites_gateway.dart';
import 'package:linthra/data/repositories/subsonic_playlist_gateway.dart';
import 'package:linthra/data/repositories/synced_favorites_repository.dart';
import 'package:linthra/data/repositories/synced_playlist_repository.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_controller.dart';
import 'package:linthra/features/settings/subsonic/subsonic_sync_controller.dart';
import 'package:linthra/features/settings/subsonic/subsonic_sync_state.dart';

import '../../../core/sources/subsonic/fake_subsonic_client.dart';

const _session = SubsonicSession(
  baseUrl: 'https://music.example.com',
  username: 'alice',
  salt: 'salt1',
  token: 'secret-token',
);

class _RecordingRepository implements MusicLibraryRepository {
  _RecordingRepository({
    this.upsertError,
    List<Track> existing = const <Track>[],
  }) : upsertedTracks = existing;

  final Object? upsertError;

  String? upsertedSourceId;
  List<Track> upsertedTracks;
  int upsertCount = 0;

  @override
  Future<void> upsertCatalog({
    required String sourceId,
    required List<Track> tracks,
    required List<Album> albums,
    required List<Artist> artists,
  }) async {
    upsertCount++;
    if (upsertError != null) throw upsertError!;
    upsertedSourceId = sourceId;
    upsertedTracks = tracks;
  }

  @override
  Future<List<Track>> getAllTracks() async => upsertedTracks;

  @override
  Future<List<Album>> getAllAlbums() async => const <Album>[];

  @override
  Future<List<Artist>> getAllArtists() async => const <Artist>[];

  @override
  Future<Track?> getTrackByUri(String uri) async => null;

  @override
  Future<void> removeTracks(List<String> trackIds) async {}
}

SubsonicMusicSource _source({
  List<SubsonicAlbumDto> albums = const <SubsonicAlbumDto>[],
  Map<String, List<SubsonicSongDto>> songsByAlbum =
      const <String, List<SubsonicSongDto>>{},
  SubsonicException? listError,
}) {
  return SubsonicMusicSource(
    session: _session,
    client: FakeSubsonicClient(
      albums: albums,
      songsByAlbum: songsByAlbum,
      listError: listError,
    ),
  );
}

ProviderContainer _container({
  required MusicLibraryRepository repository,
  SubsonicMusicSource? source,
  PlaylistRepository? playlists,
  FavoritesRepository? favorites,
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      musicLibraryRepositoryProvider.overrideWithValue(repository),
      subsonicMusicSourceProvider.overrideWithValue(source),
      if (playlists != null)
        playlistRepositoryProvider.overrideWithValue(playlists),
      if (favorites != null)
        favoritesRepositoryProvider.overrideWithValue(favorites),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('SubsonicSyncController', () {
    test('errors with a friendly message when not signed in', () async {
      final container = _container(repository: _RecordingRepository());

      await container.read(subsonicSyncControllerProvider.notifier).sync();

      final state = container.read(subsonicSyncControllerProvider);
      expect(state.status, SubsonicSyncStatus.error);
      expect(state.message, contains('Connect to your Subsonic'));
    });

    test('upserts fetched tracks under the subsonic source id', () async {
      final repository = _RecordingRepository();
      final container = _container(
        repository: repository,
        source: _source(
          albums: const <SubsonicAlbumDto>[
            SubsonicAlbumDto(id: 'al', name: 'A')
          ],
          songsByAlbum: const <String, List<SubsonicSongDto>>{
            'al': <SubsonicSongDto>[
              SubsonicSongDto(id: 's1', title: 'One'),
              SubsonicSongDto(id: 's2', title: 'Two'),
            ],
          },
        ),
      );

      await container.read(subsonicSyncControllerProvider.notifier).sync();

      final state = container.read(subsonicSyncControllerProvider);
      expect(state.status, SubsonicSyncStatus.success);
      expect(state.trackCount, 2);
      expect(repository.upsertedSourceId, 'subsonic');
      expect(repository.upsertedTracks, hasLength(2));
    });

    test('never stores a credential in a synced track uri', () async {
      final repository = _RecordingRepository();
      final container = _container(
        repository: repository,
        source: _source(
          albums: const <SubsonicAlbumDto>[
            SubsonicAlbumDto(id: 'al', name: 'A')
          ],
          songsByAlbum: const <String, List<SubsonicSongDto>>{
            'al': <SubsonicSongDto>[SubsonicSongDto(id: 's1', title: 'One')],
          },
        ),
      );

      await container.read(subsonicSyncControllerProvider.notifier).sync();

      final Track track = repository.upsertedTracks.single;
      expect(track.uri, 'subsonic:s1');
      expect(track.uri, isNot(contains('secret-token')));
      expect(track.uri, isNot(contains('salt1')));
    });

    test('reports an empty library without wiping the catalog', () async {
      final repository = _RecordingRepository();
      final container = _container(repository: repository, source: _source());

      await container.read(subsonicSyncControllerProvider.notifier).sync();

      final state = container.read(subsonicSyncControllerProvider);
      expect(state.status, SubsonicSyncStatus.success);
      expect(state.trackCount, 0);
      expect(repository.upsertCount, 0);
    });

    test('maps an unreachable server to a friendly message', () async {
      final container = _container(
        repository: _RecordingRepository(),
        source: _source(listError: SubsonicException.notReachable()),
      );

      await container.read(subsonicSyncControllerProvider.notifier).sync();

      final state = container.read(subsonicSyncControllerProvider);
      expect(state.status, SubsonicSyncStatus.error);
      expect(state.message, contains("Couldn't reach"));
    });

    test('keeps existing catalog rows when the server is unreachable',
        () async {
      // Offline-recovery guarantee: a failed sync must never wipe what's already
      // in the local catalog, so the library stays usable while the server is
      // temporarily unreachable.
      const existing = <Track>[
        Track(id: 's1', title: 'Old One', uri: 'subsonic:s1'),
      ];
      final repository = _RecordingRepository(existing: existing);
      final container = _container(
        repository: repository,
        source: _source(listError: SubsonicException.notReachable()),
      );

      await container.read(subsonicSyncControllerProvider.notifier).sync();

      expect(
        container.read(subsonicSyncControllerProvider).status,
        SubsonicSyncStatus.error,
      );
      // The write was never reached, so the existing rows are untouched.
      expect(repository.upsertCount, 0);
      expect(await repository.getAllTracks(), existing);
    });

    test('does not leak the credential through an error message', () async {
      final container = _container(
        repository: _RecordingRepository(),
        source: _source(listError: SubsonicException.unauthorized()),
      );

      await container.read(subsonicSyncControllerProvider.notifier).sync();

      expect(
        container.read(subsonicSyncControllerProvider).message,
        isNot(contains('secret-token')),
      );
    });

    test('imports Navidrome playlists and favourites and reports the counts',
        () async {
      // A shared fake client backs the playlist + favourites gateways: one
      // server playlist and one starred song.
      final syncClient = FakeSubsonicClient()
        ..playlists = <SubsonicPlaylistDto>[
          const SubsonicPlaylistDto(id: 'p-1', name: 'Road Trip'),
        ]
        ..playlistSongIds = <String, List<String>>{
          'p-1': <String>['s1'],
        }
        ..starredSongIds = <String>{'s1'};

      final playlistRepo = SyncedPlaylistRepository(
        store: InMemoryPlaylistStore(),
        gateways: <RemotePlaylistGateway>[
          SubsonicPlaylistGateway(client: syncClient, session: () => _session),
        ],
      );
      final favoritesRepo = SyncedFavoritesRepository(
        store: InMemoryFavoritesStore(),
        gateways: <RemoteFavoritesGateway>[
          SubsonicFavoritesGateway(client: syncClient, session: () => _session),
        ],
      );

      final container = _container(
        repository: _RecordingRepository(),
        source: _source(
          albums: const <SubsonicAlbumDto>[
            SubsonicAlbumDto(id: 'al', name: 'A')
          ],
          songsByAlbum: const <String, List<SubsonicSongDto>>{
            'al': <SubsonicSongDto>[SubsonicSongDto(id: 's1', title: 'One')],
          },
        ),
        playlists: playlistRepo,
        favorites: favoritesRepo,
      );

      await container.read(subsonicSyncControllerProvider.notifier).sync();

      final state = container.read(subsonicSyncControllerProvider);
      expect(state.status, SubsonicSyncStatus.success);
      expect(state.trackCount, 1);
      expect(state.playlistCount, 1);
      expect(state.favoriteCount, 1);
      expect(state.playlistsFailed, isFalse);
      expect(state.favoritesFailed, isFalse);
      expect(state.message, contains('playlist'));
      expect(state.message, contains('favorite'));

      // The imported playlist landed with the Subsonic source + namespaced uris.
      final imported = await playlistRepo.getAllPlaylists();
      expect(imported.single.source, PlaylistSource.subsonic);
      expect(imported.single.trackIds, <String>['subsonic:s1']);
      expect(favoritesRepo.isFavorite('subsonic:s1'), isTrue);
    });

    test('reports a calm partial failure when favourites cannot load',
        () async {
      final syncClient = FakeSubsonicClient()
        ..favoritesError = SubsonicException.notReachable();
      final favoritesRepo = SyncedFavoritesRepository(
        store: InMemoryFavoritesStore(),
        gateways: <RemoteFavoritesGateway>[
          SubsonicFavoritesGateway(client: syncClient, session: () => _session),
        ],
      );

      final container = _container(
        repository: _RecordingRepository(),
        source: _source(
          albums: const <SubsonicAlbumDto>[
            SubsonicAlbumDto(id: 'al', name: 'A')
          ],
          songsByAlbum: const <String, List<SubsonicSongDto>>{
            'al': <SubsonicSongDto>[SubsonicSongDto(id: 's1', title: 'One')],
          },
        ),
        favorites: favoritesRepo,
      );

      await container.read(subsonicSyncControllerProvider.notifier).sync();

      final state = container.read(subsonicSyncControllerProvider);
      // The track sync still succeeds; the favourites failure is reported calmly.
      expect(state.status, SubsonicSyncStatus.success);
      expect(state.trackCount, 1);
      expect(state.favoritesFailed, isTrue);
      expect(state.message, contains('could not be synced'));
    });

    test('surfaces a generic error when the repository upsert fails', () async {
      final container = _container(
        repository: _RecordingRepository(upsertError: Exception('disk full')),
        source: _source(
          albums: const <SubsonicAlbumDto>[
            SubsonicAlbumDto(id: 'al', name: 'A')
          ],
          songsByAlbum: const <String, List<SubsonicSongDto>>{
            'al': <SubsonicSongDto>[SubsonicSongDto(id: 's1', title: 'One')],
          },
        ),
      );

      await container.read(subsonicSyncControllerProvider.notifier).sync();

      final state = container.read(subsonicSyncControllerProvider);
      expect(state.status, SubsonicSyncStatus.error);
      expect(state.message, isNot(contains('disk full')));
      expect(state.message, contains('Please try again'));
    });
  });
}
