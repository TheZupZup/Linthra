import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/favorites_repository.dart';
import 'package:linthra/core/repositories/music_library_repository.dart';
import 'package:linthra/core/repositories/playlist_repository.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_music_source.dart';
import 'package:linthra/data/repositories/favorites_repository_provider.dart';
import 'package:linthra/data/repositories/in_memory_favorites_store.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/jellyfin_synced_favorites_repository.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/data/repositories/synced_playlist_repository.dart';
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
  _RecordingRepository({
    this.upsertError,
    List<Track> existing = const <Track>[],
  }) : upsertedTracks = existing;

  final Object? upsertError;

  String? upsertedSourceId;
  List<Track> upsertedTracks;
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
  Future<Track?> getTrackByUri(String uri) async => null;

  @override
  Future<void> removeTracks(List<String> trackIds) async {}
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
  PlaylistRepository? playlists,
  FavoritesRepository? favorites,
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      musicLibraryRepositoryProvider.overrideWithValue(repository),
      jellyfinMusicSourceProvider.overrideWithValue(source),
      if (playlists != null)
        playlistRepositoryProvider.overrideWithValue(playlists),
      if (favorites != null)
        favoritesRepositoryProvider.overrideWithValue(favorites),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// A [JellyfinMusicSource] over [client] for the playlist/favourite sync tests.
JellyfinMusicSource _sourceOver(FakeJellyfinClient client) =>
    JellyfinMusicSource(session: _session, client: client);

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

    test('keeps existing catalog rows when the server is unreachable',
        () async {
      // Offline-recovery guarantee: a failed sync must never wipe the local
      // catalog, so an already-synced library stays visible while the server is
      // temporarily offline.
      const existing = <Track>[
        Track(id: 'j1', title: 'Old One', uri: 'jellyfin:j1'),
      ];
      final repository = _RecordingRepository(existing: existing);
      final container = _container(
        repository: repository,
        source: _source(itemsError: JellyfinException.notReachable()),
      );

      await container.read(jellyfinSyncControllerProvider.notifier).sync();

      expect(
        container.read(jellyfinSyncControllerProvider).status,
        JellyfinSyncStatus.error,
      );
      // The write was never reached, so the existing rows are untouched.
      expect(repository.upsertCount, 0);
      expect(await repository.getAllTracks(), existing);
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

  group('JellyfinSyncController resilience', () {
    test('a malformed track is skipped without failing the whole sync',
        () async {
      // The headline guarantee: bad items are dropped, the good ones still sync,
      // and the outcome is a calm "synced with skipped items" — not an error.
      final client = FakeJellyfinClient(
        itemsByKind: <JellyfinItemKind, List<JellyfinItemDto>>{
          JellyfinItemKind.audio: <JellyfinItemDto>[_audio('a'), _audio('b')],
        },
      );
      client.skippedByKind = <JellyfinItemKind, int>{JellyfinItemKind.audio: 1};
      final repository = _RecordingRepository();
      final container = _container(
        repository: repository,
        source: _sourceOver(client),
      );

      await container.read(jellyfinSyncControllerProvider.notifier).sync();

      final state = container.read(jellyfinSyncControllerProvider);
      expect(state.status, JellyfinSyncStatus.success);
      expect(state.trackCount, 2);
      expect(state.skippedCount, 1);
      expect(state.syncedWithSkippedItems, isTrue);
      expect(state.message, contains('2 tracks'));
      expect(state.message, contains('Some items could not be synced'));
      // The good tracks still landed in the catalog.
      expect(repository.upsertedTracks, hasLength(2));
    });

    test('an expired token reports a sign-in-required reason', () async {
      final container = _container(
        repository: _RecordingRepository(),
        source: _source(itemsError: JellyfinException.unauthorized()),
      );

      await container.read(jellyfinSyncControllerProvider.notifier).sync();

      final state = container.read(jellyfinSyncControllerProvider);
      expect(state.status, JellyfinSyncStatus.error);
      expect(state.failureReason, JellyfinSyncFailureReason.signInRequired);
      expect(state.needsSignIn, isTrue);
    });

    test('an unreachable server reports a server-unreachable reason', () async {
      final container = _container(
        repository: _RecordingRepository(),
        source: _source(itemsError: JellyfinException.notReachable()),
      );

      await container.read(jellyfinSyncControllerProvider.notifier).sync();

      final state = container.read(jellyfinSyncControllerProvider);
      expect(state.failureReason, JellyfinSyncFailureReason.serverUnreachable);
      expect(state.needsSignIn, isFalse);
    });

    test('a transient server error reports a retry-later reason', () async {
      final container = _container(
        repository: _RecordingRepository(),
        source: _source(itemsError: JellyfinException.serverError(503)),
      );

      await container.read(jellyfinSyncControllerProvider.notifier).sync();

      final state = container.read(jellyfinSyncControllerProvider);
      expect(state.failureReason, JellyfinSyncFailureReason.retryLater);
    });

    test('a second concurrent sync is bounced by the in-flight guard',
        () async {
      final client = FakeJellyfinClient(
        itemsByKind: <JellyfinItemKind, List<JellyfinItemDto>>{
          JellyfinItemKind.audio: <JellyfinItemDto>[_audio('a')],
        },
      );
      final gate = Completer<void>();
      client.itemsGate = gate;
      final repository = _RecordingRepository();
      final container = _container(
        repository: repository,
        source: _sourceOver(client),
      );
      final notifier = container.read(jellyfinSyncControllerProvider.notifier);

      // First sync starts and parks inside the (gated) item fetch.
      final Future<void> first = notifier.sync();
      // Second sync, fired while the first is in flight, must bail at once.
      await notifier.sync();

      // Release the first and let it finish.
      gate.complete();
      await first;

      // Exactly one sync ran: one audio fetch, one catalog write.
      expect(
        client.requestedKinds
            .where((JellyfinItemKind k) => k == JellyfinItemKind.audio)
            .length,
        1,
      );
      expect(repository.upsertCount, 1);
    });

    test('a sign-out mid-sync abandons the result without writing the catalog',
        () async {
      // Cancellation safety: if the live source disappears (sign-out) or changes
      // (a different account) while the fetch is in flight, the stale result is
      // not committed over the current catalog.
      final client = FakeJellyfinClient(
        itemsByKind: <JellyfinItemKind, List<JellyfinItemDto>>{
          JellyfinItemKind.audio: <JellyfinItemDto>[_audio('a')],
        },
      );
      final gate = Completer<void>();
      client.itemsGate = gate;
      final repository = _RecordingRepository();
      final container = _container(
        repository: repository,
        source: _sourceOver(client),
      );
      final notifier = container.read(jellyfinSyncControllerProvider.notifier);

      final Future<void> run = notifier.sync();
      // Simulate sign-out: the live Jellyfin source is now gone.
      container.updateOverrides(<Override>[
        musicLibraryRepositoryProvider.overrideWithValue(repository),
        jellyfinMusicSourceProvider.overrideWithValue(null),
      ]);
      gate.complete();
      await run;

      // The fetch completed, but the now-stale result was never written.
      expect(repository.upsertCount, 0);
      // …and the abandoned run did not pin the card on a perpetual "Syncing…":
      // it reset to idle so the new account's own sync can drive the card.
      final state = container.read(jellyfinSyncControllerProvider);
      expect(state.status, JellyfinSyncStatus.idle);
      expect(state.isSyncing, isFalse);
    });
  });

  group('JellyfinSyncController playlists + favourites', () {
    SyncedPlaylistRepository playlistRepo(FakeJellyfinClient client) {
      final repo = SyncedPlaylistRepository(
        store: InMemoryPlaylistStore(),
        client: client,
        session: () => _session,
      );
      addTearDown(repo.dispose);
      return repo;
    }

    JellyfinSyncedFavoritesRepository favoritesRepo(FakeJellyfinClient client) {
      final repo = JellyfinSyncedFavoritesRepository(
        store: InMemoryFavoritesStore(),
        client: client,
        session: () => _session,
      );
      addTearDown(repo.dispose);
      return repo;
    }

    test('a library sync imports Jellyfin playlists and reports the count',
        () async {
      final client = FakeJellyfinClient(
        itemsByKind: <JellyfinItemKind, List<JellyfinItemDto>>{
          JellyfinItemKind.audio: <JellyfinItemDto>[_audio('a'), _audio('b')],
        },
      );
      client.playlists = const <JellyfinPlaylistDto>[
        JellyfinPlaylistDto(id: 'srv-1', name: 'Road Trip'),
      ];
      client.playlistEntries['srv-1'] = const <JellyfinPlaylistEntry>[
        JellyfinPlaylistEntry(itemId: 'a', playlistItemId: 'e-a'),
      ];
      final playlists = playlistRepo(client);
      final container = _container(
        repository: _RecordingRepository(),
        source: _sourceOver(client),
        playlists: playlists,
      );

      await container.read(jellyfinSyncControllerProvider.notifier).sync();

      final state = container.read(jellyfinSyncControllerProvider);
      expect(state.status, JellyfinSyncStatus.success);
      expect(state.playlistCount, 1);
      expect(state.message, contains('1 playlist'));
      // The imported playlist now lives in the repository as a synced record.
      final imported = (await playlists.getAllPlaylists())
          .where((p) => p.remoteId == 'srv-1');
      expect(imported, hasLength(1));
      expect(imported.single.name, 'Road Trip');
      // Server item ids are namespaced to jellyfin: uris on import.
      expect(imported.single.trackIds, <String>['jellyfin:a']);
    });

    test('a library sync adopts Jellyfin favourites and reports them',
        () async {
      final client = FakeJellyfinClient(
        itemsByKind: <JellyfinItemKind, List<JellyfinItemDto>>{
          JellyfinItemKind.audio: <JellyfinItemDto>[_audio('a')],
        },
      );
      client.favoriteIds = <String>{'fav-1', 'fav-2'};
      final favorites = favoritesRepo(client);
      final container = _container(
        repository: _RecordingRepository(),
        source: _sourceOver(client),
        favorites: favorites,
      );

      await container.read(jellyfinSyncControllerProvider.notifier).sync();

      final state = container.read(jellyfinSyncControllerProvider);
      expect(state.favoriteCount, 2);
      expect(state.message, contains('2 favorites'));
      // Server favourites are namespaced to jellyfin: uris.
      expect(favorites.isFavorite('jellyfin:fav-1'), isTrue);
      expect(favorites.isFavorite('jellyfin:fav-2'), isTrue);
    });

    test('a playlist sync failure is reported without failing the track sync',
        () async {
      final repository = _RecordingRepository();
      final client = FakeJellyfinClient(
        itemsByKind: <JellyfinItemKind, List<JellyfinItemDto>>{
          JellyfinItemKind.audio: <JellyfinItemDto>[_audio('a'), _audio('b')],
        },
      );
      client.playlistError = JellyfinException.notReachable();
      final container = _container(
        repository: repository,
        source: _sourceOver(client),
        playlists: playlistRepo(client),
      );

      await container.read(jellyfinSyncControllerProvider.notifier).sync();

      final state = container.read(jellyfinSyncControllerProvider);
      // Tracks still synced…
      expect(state.status, JellyfinSyncStatus.success);
      expect(state.trackCount, 2);
      expect(repository.upsertedTracks, hasLength(2));
      // …but the playlist failure is surfaced honestly.
      expect(state.playlistsFailed, isTrue);
      expect(state.message, contains('2 tracks'));
      expect(state.message, contains('could not be loaded'));
    });

    test('a favourites sync failure is reported without failing the track sync',
        () async {
      final client = FakeJellyfinClient(
        itemsByKind: <JellyfinItemKind, List<JellyfinItemDto>>{
          JellyfinItemKind.audio: <JellyfinItemDto>[_audio('a')],
        },
      );
      client.favoritesError = JellyfinException.notReachable();
      final container = _container(
        repository: _RecordingRepository(),
        source: _sourceOver(client),
        favorites: favoritesRepo(client),
      );

      await container.read(jellyfinSyncControllerProvider.notifier).sync();

      final state = container.read(jellyfinSyncControllerProvider);
      expect(state.status, JellyfinSyncStatus.success);
      expect(state.favoritesFailed, isTrue);
      expect(state.message, contains('could not be synced'));
    });

    test('no token leaks into the combined sync message', () async {
      final client = FakeJellyfinClient(
        itemsByKind: <JellyfinItemKind, List<JellyfinItemDto>>{
          JellyfinItemKind.audio: <JellyfinItemDto>[_audio('a')],
        },
      );
      client.playlists = const <JellyfinPlaylistDto>[
        JellyfinPlaylistDto(id: 'srv', name: 'Mix'),
      ];
      client.playlistEntries['srv'] = const <JellyfinPlaylistEntry>[
        JellyfinPlaylistEntry(itemId: 'a', playlistItemId: 'e-a'),
      ];
      client.favoriteIds = <String>{'a'};
      final container = _container(
        repository: _RecordingRepository(),
        source: _sourceOver(client),
        playlists: playlistRepo(client),
        favorites: favoritesRepo(client),
      );

      await container.read(jellyfinSyncControllerProvider.notifier).sync();

      final state = container.read(jellyfinSyncControllerProvider);
      expect(state.message, isNot(contains('secret-token')));
    });
  });
}
