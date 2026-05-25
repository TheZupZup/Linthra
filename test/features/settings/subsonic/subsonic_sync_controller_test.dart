import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/music_library_repository.dart';
import 'package:linthra/core/sources/subsonic/subsonic_api.dart';
import 'package:linthra/core/sources/subsonic/subsonic_exception.dart';
import 'package:linthra/core/sources/subsonic/subsonic_music_source.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
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
  _RecordingRepository({this.upsertError});

  final Object? upsertError;

  String? upsertedSourceId;
  List<Track> upsertedTracks = const <Track>[];
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
  Future<Track?> getTrackById(String id) async => null;

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
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      musicLibraryRepositoryProvider.overrideWithValue(repository),
      subsonicMusicSourceProvider.overrideWithValue(source),
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
