import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/music_library_repository.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_music_source.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_sync_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_sync_state.dart';

import '../../../core/sources/jellyfin/fake_jellyfin_client.dart';

const _session = JellyfinSession(
  baseUrl: 'https://music.example.com',
  userId: 'user-1',
  accessToken: 'secret-token',
  deviceId: 'device-1',
  userName: 'alice',
  serverName: 'Home',
);

/// A recording [MusicLibraryRepository] that captures the last upsert so a test
/// can assert what the sync stored, and can be made to throw on upsert.
class _RecordingRepository implements MusicLibraryRepository {
  _RecordingRepository({this.upsertError});

  final Object? upsertError;

  String? upsertedSourceId;
  List<Track> upsertedTracks = const <Track>[];
  List<Album> upsertedAlbums = const <Album>[];
  List<Artist> upsertedArtists = const <Artist>[];
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
    upsertedAlbums = albums;
    upsertedArtists = artists;
  }

  @override
  Future<List<Track>> getAllTracks() async => upsertedTracks;

  @override
  Future<List<Album>> getAllAlbums() async => upsertedAlbums;

  @override
  Future<List<Artist>> getAllArtists() async => upsertedArtists;

  @override
  Future<Track?> getTrackById(String id) async => null;
}

JellyfinItemDto _audio(String id) => JellyfinItemDto(
      id: id,
      name: 'Track $id',
      album: 'Album',
      artists: const <String>['Artist'],
      runTimeTicks: 1000000,
      indexNumber: 1,
    );

/// Builds a real [JellyfinMusicSource] over a [FakeJellyfinClient] — the "fake
/// source" for these tests, with no real HTTP or server.
JellyfinMusicSource _source({
  Map<JellyfinItemKind, List<JellyfinItemDto>> items =
      const <JellyfinItemKind, List<JellyfinItemDto>>{},
  JellyfinException? itemsError,
}) {
  return JellyfinMusicSource(
    session: _session,
    client: FakeJellyfinClient(itemsByKind: items, itemsError: itemsError),
  );
}

ProviderContainer _container({
  required MusicLibraryRepository repository,
  JellyfinMusicSource? source,
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      musicLibraryRepositoryProvider.overrideWithValue(repository),
      jellyfinMusicSourceProvider.overrideWithValue(source),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('JellyfinSyncController', () {
    test('starts idle', () {
      final container = _container(repository: _RecordingRepository());
      expect(
        container.read(jellyfinSyncControllerProvider).status,
        JellyfinSyncStatus.idle,
      );
    });

    test('errors with a friendly message when not signed in', () async {
      final container = _container(repository: _RecordingRepository());

      await container.read(jellyfinSyncControllerProvider.notifier).sync();

      final state = container.read(jellyfinSyncControllerProvider);
      expect(state.status, JellyfinSyncStatus.error);
      expect(state.message, contains('Connect to your Jellyfin server'));
    });

    test('upserts fetched tracks under the jellyfin source id', () async {
      final repository = _RecordingRepository();
      final container = _container(
        repository: repository,
        source: _source(
          items: <JellyfinItemKind, List<JellyfinItemDto>>{
            JellyfinItemKind.audio: <JellyfinItemDto>[_audio('a'), _audio('b')],
            JellyfinItemKind.album: <JellyfinItemDto>[
              const JellyfinItemDto(id: 'alb', name: 'Album'),
            ],
            JellyfinItemKind.artist: <JellyfinItemDto>[
              const JellyfinItemDto(id: 'art', name: 'Artist'),
            ],
          },
        ),
      );

      await container.read(jellyfinSyncControllerProvider.notifier).sync();

      final state = container.read(jellyfinSyncControllerProvider);
      expect(state.status, JellyfinSyncStatus.success);
      expect(state.trackCount, 2);
      expect(state.message, contains('2 tracks'));
      expect(repository.upsertedSourceId, 'jellyfin');
      expect(repository.upsertedTracks, hasLength(2));
      expect(repository.upsertedAlbums, hasLength(1));
      expect(repository.upsertedArtists, hasLength(1));
    });

    test('never stores the access token in a synced track uri', () async {
      final repository = _RecordingRepository();
      final container = _container(
        repository: repository,
        source: _source(
          items: <JellyfinItemKind, List<JellyfinItemDto>>{
            JellyfinItemKind.audio: <JellyfinItemDto>[_audio('a')],
          },
        ),
      );

      await container.read(jellyfinSyncControllerProvider.notifier).sync();

      final Track track = repository.upsertedTracks.single;
      expect(track.uri, 'jellyfin:a');
      expect(track.uri, isNot(contains('secret-token')));
    });

    test('reports an empty library without wiping the catalog', () async {
      final repository = _RecordingRepository();
      final container = _container(
        repository: repository,
        source: _source(),
      );

      await container.read(jellyfinSyncControllerProvider.notifier).sync();

      final state = container.read(jellyfinSyncControllerProvider);
      expect(state.status, JellyfinSyncStatus.success);
      expect(state.trackCount, 0);
      expect(state.message, contains('empty'));
      // Nothing was upserted, so an existing catalog is left untouched.
      expect(repository.upsertCount, 0);
    });

    test('maps an unreachable server to a friendly message', () async {
      final container = _container(
        repository: _RecordingRepository(),
        source: _source(itemsError: JellyfinException.notReachable()),
      );

      await container.read(jellyfinSyncControllerProvider.notifier).sync();

      final state = container.read(jellyfinSyncControllerProvider);
      expect(state.status, JellyfinSyncStatus.error);
      expect(state.message, contains("Couldn't reach"));
    });

    test('maps an expired token to a sign-in-again message', () async {
      final container = _container(
        repository: _RecordingRepository(),
        source: _source(itemsError: JellyfinException.unauthorized()),
      );

      await container.read(jellyfinSyncControllerProvider.notifier).sync();

      final state = container.read(jellyfinSyncControllerProvider);
      expect(state.status, JellyfinSyncStatus.error);
      expect(state.message, contains('session has expired'));
    });

    test('does not leak the token through an error message', () async {
      final container = _container(
        repository: _RecordingRepository(),
        source: _source(itemsError: JellyfinException.unauthorized()),
      );

      await container.read(jellyfinSyncControllerProvider.notifier).sync();

      final state = container.read(jellyfinSyncControllerProvider);
      expect(state.message, isNot(contains('secret-token')));
    });

    test('surfaces a generic error when the repository upsert fails', () async {
      final container = _container(
        repository: _RecordingRepository(upsertError: Exception('disk full')),
        source: _source(
          items: <JellyfinItemKind, List<JellyfinItemDto>>{
            JellyfinItemKind.audio: <JellyfinItemDto>[_audio('a')],
          },
        ),
      );

      await container.read(jellyfinSyncControllerProvider.notifier).sync();

      final state = container.read(jellyfinSyncControllerProvider);
      expect(state.status, JellyfinSyncStatus.error);
      // The raw error is not surfaced to the user.
      expect(state.message, isNot(contains('disk full')));
      expect(state.message, contains('Please try again'));
    });
  });
}
