import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/incremental_catalog_writer.dart';
import 'package:linthra/core/repositories/music_library_repository.dart';
import 'package:linthra/core/repositories/plex_sync_cache_store.dart';
import 'package:linthra/core/sources/plex/plex_api.dart';
import 'package:linthra/core/sources/plex/plex_exception.dart';
import 'package:linthra/data/repositories/in_memory_plex_session_store.dart';
import 'package:linthra/data/repositories/in_memory_plex_sync_cache_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/plex_session_store_provider.dart';
import 'package:linthra/data/repositories/plex_sync_cache_store_provider.dart';
import 'package:linthra/features/settings/plex/plex_settings_controller.dart';
import 'package:linthra/features/settings/plex/plex_settings_providers.dart';
import 'package:linthra/features/settings/plex/plex_sync_controller.dart';
import 'package:linthra/features/settings/plex/plex_sync_state.dart';

import '../../../core/sources/plex/fake_plex_client.dart';

const String _token = 'super-secret-plex-token';

/// `machineIdentifier` matches [FakePlexClient]'s default identity, so a
/// re-connect in these tests counts as the same server.
const PlexSession _session = PlexSession(
  baseUrl: 'https://plex.example.com:32400',
  token: _token,
  machineIdentifier: 'fake-machine-id',
  clientIdentifier: 'install-1',
  selectedSectionKeys: <String>['5'],
);

const PlexDirectory _musicSection =
    PlexDirectory(key: '5', title: 'Music', type: 'artist');

const PlexMetadata _trackItem = PlexMetadata(
  ratingKey: '101',
  type: 'track',
  title: 'Aurora',
  grandparentTitle: 'The Band',
  parentTitle: 'First Light',
  duration: 215000,
  thumb: '/library/metadata/101/thumb/1',
);
const PlexMetadata _secondTrackItem =
    PlexMetadata(ratingKey: '102', type: 'track', title: 'Dusk');

// Albums/artists are intentionally still present in the fixture but never
// requested: the sync reads tracks only (the library derives groupings from
// tracks), so listing albums/artists would be wasted library walks.
const PlexMetadata _albumItem = PlexMetadata(
  ratingKey: '201',
  type: 'album',
  title: 'First Light',
  parentTitle: 'The Band',
);
const PlexMetadata _artistItem =
    PlexMetadata(ratingKey: '301', type: 'artist', title: 'The Band');

const Map<PlexMetadataType, List<PlexMetadata>> _libraryItems =
    <PlexMetadataType, List<PlexMetadata>>{
  PlexMetadataType.track: <PlexMetadata>[_trackItem, _secondTrackItem],
  PlexMetadataType.album: <PlexMetadata>[_albumItem],
  PlexMetadataType.artist: <PlexMetadata>[_artistItem],
};

/// `count` track items, for exercising the batched (chunked) write path.
List<PlexMetadata> _trackItems(int count) => <PlexMetadata>[
      for (int i = 0; i < count; i++)
        PlexMetadata(ratingKey: 'r$i', type: 'track', title: 'Track $i'),
    ];

/// Records every catalog write so tests can assert exactly what reached the
/// catalog and in how many batches. Implements the incremental capability so
/// the controller exercises its progressive path (a whole-slice `upsertCatalog`
/// is kept only for interface completeness and is not used by the controller).
class _RecordingRepository
    implements MusicLibraryRepository, IncrementalCatalogWriter {
  _RecordingRepository({
    this.beginError,
    this.appendGate,
    List<Track> existing = const <Track>[],
  }) {
    stored.addAll(existing);
  }

  /// When set, the first (begin) write throws it, so a storage failure can be
  /// proven to surface friendly and never half-write.
  final Object? beginError;

  /// When set, [appendToCatalog] awaits it before applying its batch, so a test
  /// can hold a sync mid-write and observe the already-stored batches.
  final Future<void>? appendGate;

  String? lastSourceId;

  /// The catalog accumulated across the current begin/append run.
  final List<Track> stored = <Track>[];

  /// Each batch handed to begin/append, in order.
  final List<List<Track>> batches = <List<Track>>[];

  int beginCount = 0;
  int appendCount = 0;
  int upsertCount = 0;

  int get writeCount => beginCount + appendCount + upsertCount;

  @override
  Future<void> beginCatalogReplacement({
    required String sourceId,
    required List<Track> tracks,
  }) async {
    beginCount++;
    if (beginError != null) throw beginError!;
    lastSourceId = sourceId;
    stored
      ..clear()
      ..addAll(tracks);
    batches.add(List<Track>.of(tracks));
  }

  @override
  Future<void> appendToCatalog({
    required String sourceId,
    required List<Track> tracks,
  }) async {
    appendCount++;
    final Future<void>? gate = appendGate;
    if (gate != null) await gate;
    lastSourceId = sourceId;
    stored.addAll(tracks);
    batches.add(List<Track>.of(tracks));
  }

  @override
  Future<void> upsertCatalog({
    required String sourceId,
    required List<Track> tracks,
    required List<Album> albums,
    required List<Artist> artists,
  }) async {
    upsertCount++;
    if (beginError != null) throw beginError!;
    lastSourceId = sourceId;
    stored
      ..clear()
      ..addAll(tracks);
    batches.add(List<Track>.of(tracks));
  }

  @override
  Future<List<Track>> getAllTracks() async => List<Track>.of(stored);

  @override
  Future<List<Album>> getAllAlbums() async => const <Album>[];

  @override
  Future<List<Artist>> getAllArtists() async => const <Artist>[];

  @override
  Future<Track?> getTrackByUri(String uri) async => null;

  @override
  Future<void> removeTracks(List<String> trackIds) async {}
}

/// A [FakePlexClient] whose item listings block until [gate] completes, so a
/// test can hold a sync mid-scan and race it against selection changes (and
/// prove playback still resolves while a scan is in flight — `fetchMetadata`,
/// the play-time lookup, is deliberately *not* gated).
class _GatedPlexClient extends FakePlexClient {
  _GatedPlexClient({
    super.sections,
    super.itemsByType,
    super.metadataByRatingKey,
  });

  Completer<void> gate = Completer<void>();

  @override
  Future<List<PlexMetadata>> fetchSectionItems({
    required String baseUrl,
    required String token,
    required String sectionKey,
    required PlexMetadataType itemType,
  }) async {
    await gate.future;
    return super.fetchSectionItems(
      baseUrl: baseUrl,
      token: token,
      sectionKey: sectionKey,
      itemType: itemType,
    );
  }
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

ProviderContainer _container({
  FakePlexClient? client,
  PlexSession? session,
  MusicLibraryRepository? repository,
  PlexSyncCacheStore? cacheStore,
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      plexClientProvider.overrideWithValue(
        client ??
            FakePlexClient(
              sections: const [_musicSection],
              itemsByType: _libraryItems,
            ),
      ),
      plexSessionStoreProvider.overrideWithValue(
        InMemoryPlexSessionStore(initialSession: session),
      ),
      musicLibraryRepositoryProvider
          .overrideWithValue(repository ?? _RecordingRepository()),
      // A caller passes a shared cache store to model the durable signature
      // surviving a "restart" (a fresh container built over the same store).
      plexSyncCacheStoreProvider
          .overrideWithValue(cacheStore ?? InMemoryPlexSyncCacheStore()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('sync', () {
    test('reports a friendly error when not connected, touching nothing',
        () async {
      final repo = _RecordingRepository();
      final container = _container(repository: repo);
      await container
          .read(plexSettingsControllerProvider.notifier)
          .ensureLoaded();

      await container.read(plexSyncControllerProvider.notifier).sync();

      final state = container.read(plexSyncControllerProvider);
      expect(state.isError, isTrue);
      expect(state.message, contains('Connect to your Plex server'));
      expect(repo.writeCount, 0);
    });

    test('keeps existing catalog rows when the server is unreachable',
        () async {
      // Offline-recovery guarantee: a failed scan must not delete the Plex slice
      // it was about to replace — the begin/append writes are never reached, so
      // the already-synced rows stay visible while the server is offline.
      const existing = <Track>[
        Track(id: 'p1', title: 'Old One', uri: 'plex:p1'),
      ];
      final repo = _RecordingRepository(existing: existing);
      final container = _container(
        client: FakePlexClient(itemsError: PlexException.notReachable()),
        session: _session,
        repository: repo,
      );
      await container
          .read(plexSettingsControllerProvider.notifier)
          .ensureLoaded();

      await container.read(plexSyncControllerProvider.notifier).sync();

      expect(container.read(plexSyncControllerProvider).isError, isTrue);
      expect(repo.writeCount, 0);
      expect(await repo.getAllTracks(), existing);
    });

    test(
        'pulls the selected libraries (tracks only) into the catalog under the '
        'plex id', () async {
      final client = FakePlexClient(
        sections: const [_musicSection],
        itemsByType: _libraryItems,
      );
      final repo = _RecordingRepository();
      final container =
          _container(client: client, session: _session, repository: repo);
      await container
          .read(plexSettingsControllerProvider.notifier)
          .ensureLoaded();

      await container.read(plexSyncControllerProvider.notifier).sync();

      expect(repo.lastSourceId, 'plex');
      expect(
        repo.stored.map((Track t) => t.uri),
        <String>['plex:101', 'plex:102'],
      );
      // What reaches the (persisted) catalog stays credential-free: opaque
      // plex: URIs and plex-thumb: references — never a tokenized URL.
      for (final Track track in repo.stored) {
        expect(track.uri, isNot(contains(_token)));
        expect(track.uri, isNot(contains('X-Plex-Token')));
        final Uri? artwork = track.artworkUri;
        if (artwork != null) {
          expect(artwork.scheme, 'plex-thumb');
          expect(artwork.toString(), isNot(contains(_token)));
        }
      }
      // Only the track kind is listed (no album/artist walks), scoped to the
      // selected section.
      expect(
        client.itemRequests.map((r) => r.itemType).toSet(),
        <PlexMetadataType>{PlexMetadataType.track},
      );
      expect(
        client.itemRequests.map((r) => r.sectionKey).toSet(),
        <String>{'5'},
      );
      expect(client.itemRequests, hasLength(1));

      final state = container.read(plexSyncControllerProvider);
      expect(state.status, PlexSyncStatus.done);
      expect(state.trackCount, 2);
      expect(state.message, contains('Synced 2 tracks'));
    });

    test(
        'selected libraries with no tracks report honestly and still '
        'replace the catalog', () async {
      final repo = _RecordingRepository();
      final container = _container(
        client: FakePlexClient(sections: const [_musicSection]),
        session: _session,
        repository: repo,
      );
      await container
          .read(plexSettingsControllerProvider.notifier)
          .ensureLoaded();

      await container.read(plexSyncControllerProvider.notifier).sync();

      // The empty result is written (a previously wider selection's rows must
      // not linger), and the message says what happened.
      expect(repo.beginCount, 1);
      expect(repo.stored, isEmpty);
      final state = container.read(plexSyncControllerProvider);
      expect(state.status, PlexSyncStatus.done);
      expect(state.trackCount, 0);
      expect(state.message, contains('no tracks yet'));
    });

    test('an empty selection clears previously synced Plex rows', () async {
      final repo = _RecordingRepository();
      final container = _container(
        session: _session.copyWith(selectedSectionKeys: const <String>[]),
        repository: repo,
      );
      await container
          .read(plexSettingsControllerProvider.notifier)
          .ensureLoaded();

      await container.read(plexSyncControllerProvider.notifier).sync();

      expect(repo.beginCount, 1);
      expect(repo.lastSourceId, 'plex');
      expect(repo.stored, isEmpty);
      // An empty selection needs no server walk.
      final client = container.read(plexClientProvider) as FakePlexClient;
      expect(client.itemRequests, isEmpty);
      final state = container.read(plexSyncControllerProvider);
      expect(state.status, PlexSyncStatus.done);
      expect(state.message, contains('No music libraries are selected'));
    });
  });

  group('incremental writes', () {
    test('a large library is written progressively in capped batches',
        () async {
      final repo = _RecordingRepository();
      final container = _container(
        client: FakePlexClient(
          sections: const [_musicSection],
          itemsByType: <PlexMetadataType, List<PlexMetadata>>{
            PlexMetadataType.track: _trackItems(250),
          },
        ),
        session: _session,
        repository: repo,
      );
      await container
          .read(plexSettingsControllerProvider.notifier)
          .ensureLoaded();

      await container.read(plexSyncControllerProvider.notifier).sync();

      // 250 tracks → one begin (100) + two appends (100, 50).
      expect(repo.beginCount, 1);
      expect(repo.appendCount, 2);
      expect(repo.batches.map((b) => b.length), <int>[100, 100, 50]);
      // No batch exceeds the chunk size, and the whole library landed in order.
      expect(repo.batches.every((b) => b.length <= 100), isTrue);
      expect(repo.stored, hasLength(250));
      expect(
        repo.stored.map((Track t) => t.id),
        _trackItems(250).map((PlexMetadata m) => m.ratingKey),
      );
      expect(container.read(plexSyncControllerProvider).trackCount, 250);
    });

    test('the first batch is in the catalog before the sync finishes',
        () async {
      final gate = Completer<void>();
      final repo = _RecordingRepository(appendGate: gate.future);
      final container = _container(
        client: FakePlexClient(
          sections: const [_musicSection],
          itemsByType: <PlexMetadataType, List<PlexMetadata>>{
            PlexMetadataType.track: _trackItems(150),
          },
        ),
        session: _session,
        repository: repo,
      );
      await container
          .read(plexSettingsControllerProvider.notifier)
          .ensureLoaded();

      bool finished = false;
      final Future<void> running = container
          .read(plexSyncControllerProvider.notifier)
          .sync()
        ..then((_) => finished = true).ignore();

      // Advance until the sync is parked on the gated second batch.
      for (int i = 0; i < 50 && repo.appendCount == 0; i++) {
        await _settle();
      }

      // The first 100 tracks are already stored (the library could show them)
      // while the sync is still writing the rest.
      expect(repo.appendCount, 1);
      expect(repo.stored, hasLength(100));
      expect(finished, isFalse);
      expect(container.read(plexSyncControllerProvider).isWriting, isTrue);

      gate.complete();
      await running;

      expect(repo.stored, hasLength(150));
      expect(container.read(plexSyncControllerProvider).isDone, isTrue);
    });

    test('an unchanged library skips the rebuild on a re-sync', () async {
      final repo = _RecordingRepository();
      final container = _container(session: _session, repository: repo);
      final sync = container.read(plexSyncControllerProvider.notifier);
      await container
          .read(plexSettingsControllerProvider.notifier)
          .ensureLoaded();

      await sync.sync();
      expect(repo.beginCount, 1);
      expect(repo.stored, hasLength(2));

      await sync.sync();

      // Nothing changed, so the database was not rebuilt a second time.
      expect(repo.beginCount, 1);
      expect(repo.appendCount, 0);
      final state = container.read(plexSyncControllerProvider);
      expect(state.isDone, isTrue);
      expect(state.trackCount, 2);
      expect(state.message, contains('already up to date'));
    });

    test('a changed library is rebuilt rather than skipped', () async {
      final client = FakePlexClient(
        sections: const [_musicSection],
        itemsByType: <PlexMetadataType, List<PlexMetadata>>{
          PlexMetadataType.track: const <PlexMetadata>[
            _trackItem,
            _secondTrackItem,
          ],
        },
      );
      final repo = _RecordingRepository();
      final container =
          _container(client: client, session: _session, repository: repo);
      final sync = container.read(plexSyncControllerProvider.notifier);
      await container
          .read(plexSettingsControllerProvider.notifier)
          .ensureLoaded();

      await sync.sync();
      expect(repo.beginCount, 1);
      expect(repo.stored, hasLength(2));

      // The server gains a track between syncs.
      client.itemsByType = <PlexMetadataType, List<PlexMetadata>>{
        PlexMetadataType.track: const <PlexMetadata>[
          _trackItem,
          _secondTrackItem,
          PlexMetadata(ratingKey: '103', type: 'track', title: 'Twilight'),
        ],
      };

      await sync.sync();

      expect(repo.beginCount, 2);
      expect(repo.stored, hasLength(3));
      final state = container.read(plexSyncControllerProvider);
      expect(state.isDone, isTrue);
      expect(state.message, contains('Synced 3 tracks'));
    });
  });

  group('durable signature (across restarts)', () {
    test(
        'a persisted signature skips the rebuild on the first sync after a '
        'restart', () async {
      final repo = _RecordingRepository();
      final cache = InMemoryPlexSyncCacheStore();

      // First launch: a sync fills the catalog and persists the signature.
      final first =
          _container(session: _session, repository: repo, cacheStore: cache);
      await first.read(plexSettingsControllerProvider.notifier).ensureLoaded();
      await first.read(plexSyncControllerProvider.notifier).sync();
      expect(repo.beginCount, 1);
      expect(repo.stored, hasLength(2));

      // Second launch: fresh controllers, but the SAME durable cache and the
      // SAME (SQLite-like) catalog, and the server is unchanged.
      final second =
          _container(session: _session, repository: repo, cacheStore: cache);
      await second.read(plexSettingsControllerProvider.notifier).ensureLoaded();
      await second.read(plexSyncControllerProvider.notifier).sync();

      // The catalog was not rebuilt again — the persisted signature recognised
      // the unchanged library across the "restart", which the old in-memory-only
      // signature could not.
      expect(repo.beginCount, 1);
      expect(repo.appendCount, 0);
      final state = second.read(plexSyncControllerProvider);
      expect(state.isDone, isTrue);
      expect(state.message, contains('already up to date'));
    });

    test('a library changed while the app was closed still rebuilds', () async {
      final client = FakePlexClient(
        sections: const [_musicSection],
        itemsByType: <PlexMetadataType, List<PlexMetadata>>{
          PlexMetadataType.track: const <PlexMetadata>[
            _trackItem,
            _secondTrackItem,
          ],
        },
      );
      final repo = _RecordingRepository();
      final cache = InMemoryPlexSyncCacheStore();

      final first = _container(
          client: client,
          session: _session,
          repository: repo,
          cacheStore: cache);
      await first.read(plexSettingsControllerProvider.notifier).ensureLoaded();
      await first.read(plexSyncControllerProvider.notifier).sync();
      expect(repo.beginCount, 1);

      // The server gains a track between launches.
      client.itemsByType = <PlexMetadataType, List<PlexMetadata>>{
        PlexMetadataType.track: const <PlexMetadata>[
          _trackItem,
          _secondTrackItem,
          PlexMetadata(ratingKey: '103', type: 'track', title: 'Twilight'),
        ],
      };

      final second = _container(
          client: client,
          session: _session,
          repository: repo,
          cacheStore: cache);
      await second.read(plexSettingsControllerProvider.notifier).ensureLoaded();
      await second.read(plexSyncControllerProvider.notifier).sync();

      expect(repo.beginCount, 2);
      expect(repo.stored, hasLength(3));
      expect(
        second.read(plexSyncControllerProvider).message,
        contains('Synced 3 tracks'),
      );
    });

    test('a signature stored for a different server is ignored', () async {
      final repo = _RecordingRepository();
      // The cache holds a fingerprint for some OTHER Plex server.
      final cache = InMemoryPlexSyncCacheStore(
        machineIdentifier: 'a-different-machine-id',
        signature: 'stale-signature',
      );

      final container =
          _container(session: _session, repository: repo, cacheStore: cache);
      await container
          .read(plexSettingsControllerProvider.notifier)
          .ensureLoaded();
      await container.read(plexSyncControllerProvider.notifier).sync();

      // The stale fingerprint never matched this server, so the catalog rebuilt
      // rather than skipping into another server's items.
      expect(repo.beginCount, 1);
      expect(repo.stored, hasLength(2));
      expect(
        container.read(plexSyncControllerProvider).message,
        contains('Synced 2 tracks'),
      );
    });

    test(
        'removeSyncedCatalog clears the durable signature so a later sync '
        'rebuilds rather than skipping into an empty catalog', () async {
      final repo = _RecordingRepository();
      final cache = InMemoryPlexSyncCacheStore();

      final first =
          _container(session: _session, repository: repo, cacheStore: cache);
      await first.read(plexSettingsControllerProvider.notifier).ensureLoaded();
      final firstSync = first.read(plexSyncControllerProvider.notifier);
      await firstSync.sync();
      expect(repo.stored, hasLength(2));

      // Disconnect-style cleanup empties the catalog; it must also forget the
      // fingerprint, or a reconnect would skip against it and stay empty.
      await firstSync.removeSyncedCatalog();
      expect(await cache.readSignature(_session.machineIdentifier), isNull);
      expect(repo.stored, isEmpty);

      // Next launch re-syncs the same (unchanged) server: with no durable
      // signature it rebuilds, repopulating the catalog instead of skipping.
      final second =
          _container(session: _session, repository: repo, cacheStore: cache);
      await second.read(plexSettingsControllerProvider.notifier).ensureLoaded();
      await second.read(plexSyncControllerProvider.notifier).sync();
      expect(repo.stored, hasLength(2));
      expect(
        second.read(plexSyncControllerProvider).message,
        contains('Synced 2 tracks'),
      );
    });
  });

  group('playback during a scan', () {
    test('a track still resolves to a stream URL while a scan is in flight',
        () async {
      final client = _GatedPlexClient(
        sections: const [_musicSection],
        itemsByType: _libraryItems,
        metadataByRatingKey: const <String, PlexMetadata>{
          '500': PlexMetadata(
            ratingKey: '500',
            type: 'track',
            title: 'Now Playing',
            media: <PlexMedia>[
              PlexMedia(
                parts: <PlexPart>[PlexPart(key: '/library/parts/1/file.flac')],
              ),
            ],
          ),
        },
      );
      final container =
          _container(client: client, session: _session, repository: null);
      await container
          .read(plexSettingsControllerProvider.notifier)
          .ensureLoaded();

      // Start a sync; it parks at the gated section walk (scanning).
      final Future<void> scanning =
          container.read(plexSyncControllerProvider.notifier).sync();
      for (int i = 0;
          i < 50 && !container.read(plexSyncControllerProvider).isScanning;
          i++) {
        await _settle();
      }
      expect(container.read(plexSyncControllerProvider).isScanning, isTrue);

      // Playback resolution (the play-time metadata lookup) is not blocked by
      // the in-flight scan and returns a playable URL.
      final source = container.read(plexMusicSourceProvider)!;
      final Uri? uri = await source.resolvePlayableUri(
        const Track(id: '500', title: 'Now Playing', uri: 'plex:500'),
      );
      expect(uri, isNotNull);
      expect(uri.toString(), contains('/library/parts/1/file.flac'));
      // The scan is still running — playback didn't have to wait for it.
      expect(container.read(plexSyncControllerProvider).isScanning, isTrue);

      client.gate.complete();
      await scanning;
      expect(container.read(plexSyncControllerProvider).isDone, isTrue);
    });
  });

  group('failures', () {
    test('maps each failure kind to a friendly, token-free message', () async {
      final cases = <PlexException, String>{
        PlexException.notReachable(): "Couldn't reach your Plex server",
        PlexException.unauthorized(): 'rejected by the server',
        PlexException.notPlex(): "didn't respond like a Plex Media Server",
        PlexException.serverError(503): 'reported an error',
        PlexException.notFound(): "A selected library wasn't found",
        PlexException.unsupportedResponse(): 'could not use',
      };
      for (final MapEntry<PlexException, String> entry in cases.entries) {
        final repo = _RecordingRepository();
        final container = _container(
          client: FakePlexClient(itemsError: entry.key),
          session: _session,
          repository: repo,
        );
        await container
            .read(plexSettingsControllerProvider.notifier)
            .ensureLoaded();

        await container.read(plexSyncControllerProvider.notifier).sync();

        final state = container.read(plexSyncControllerProvider);
        expect(state.isError, isTrue, reason: '${entry.key.kind}');
        expect(state.message, contains(entry.value),
            reason: '${entry.key.kind}');
        expect(state.message, isNot(contains(_token)),
            reason: '${entry.key.kind}');
        // A failed scan never half-writes the catalog.
        expect(repo.writeCount, 0, reason: '${entry.key.kind}');
      }
    });

    test('a storage failure surfaces a friendly message', () async {
      final container = _container(
        session: _session,
        repository: _RecordingRepository(beginError: StateError('disk full')),
      );
      await container
          .read(plexSettingsControllerProvider.notifier)
          .ensureLoaded();

      await container.read(plexSyncControllerProvider.notifier).sync();

      final state = container.read(plexSyncControllerProvider);
      expect(state.isError, isTrue);
      expect(state.message, contains('Something went wrong'));
      expect(state.message, isNot(contains(_token)));
    });
  });

  group('coalescing', () {
    test(
        'a selection change during a sync re-runs once against the newest '
        'selection; a manual tap mid-sync is a no-op', () async {
      final client = _GatedPlexClient(
        sections: const [
          _musicSection,
          PlexDirectory(key: '9', title: 'Vinyl rips', type: 'artist'),
        ],
        itemsByType: _libraryItems,
      );
      final repo = _RecordingRepository();
      final container =
          _container(client: client, session: _session, repository: repo);
      final settings = container.read(plexSettingsControllerProvider.notifier);
      await settings.ensureLoaded();
      final sync = container.read(plexSyncControllerProvider.notifier);

      final Future<void> first = sync.sync();
      await _settle();
      expect(container.read(plexSyncControllerProvider).isSyncing, isTrue);

      // While the walk is held at the gate, the user widens the selection (the
      // settings controller kicks syncAfterSelectionChange itself) and also
      // mashes the sync button — neither may stack extra walks.
      await settings.setSelectedSections(const <String>['5', '9']);
      await sync.sync();

      client.gate.complete();
      await first;
      await _settle();

      // Exactly two write passes: the original plus one coalesced re-run.
      expect(repo.beginCount, 2);
      // Track-only walks: 1 section first, then both sections on the re-run.
      expect(client.itemRequests, hasLength(1 + 2));
      expect(
        client.itemRequests.skip(1).map((r) => r.sectionKey).toSet(),
        <String>{'5', '9'},
      );
      expect(
        client.itemRequests.map((r) => r.itemType).toSet(),
        <PlexMetadataType>{PlexMetadataType.track},
      );
      expect(
        container.read(plexSyncControllerProvider).status,
        PlexSyncStatus.done,
      );
    });
  });

  group('selection-driven sync', () {
    test('toggling a library kicks a background sync that fills the catalog',
        () async {
      final repo = _RecordingRepository();
      final container = _container(repository: repo);
      final settings = container.read(plexSettingsControllerProvider.notifier);
      await settings.ensureLoaded();
      await settings.connect(url: 'plex.example.com', token: _token);
      await _settle();

      await settings.toggleSection('5', included: true);
      await _settle();

      expect(repo.lastSourceId, 'plex');
      expect(
        repo.stored.map((Track t) => t.uri),
        <String>['plex:101', 'plex:102'],
      );
      final state = container.read(plexSyncControllerProvider);
      expect(state.status, PlexSyncStatus.done);
      expect(state.trackCount, 2);
    });

    test('deselecting the last library prunes its tracks from the catalog',
        () async {
      final repo = _RecordingRepository();
      final container = _container(session: _session, repository: repo);
      final settings = container.read(plexSettingsControllerProvider.notifier);
      await settings.ensureLoaded();
      await container.read(plexSyncControllerProvider.notifier).sync();
      expect(repo.stored, isNotEmpty);

      await settings.toggleSection('5', included: false);
      await _settle();

      expect(repo.stored, isEmpty);
      expect(
        container.read(plexSyncControllerProvider).message,
        contains('No music libraries are selected'),
      );
    });
  });

  group('token safety', () {
    test('no sync outcome ever carries the token in its message', () async {
      final outcomes = <PlexSyncState>[];

      // Success.
      var container = _container(session: _session);
      await container
          .read(plexSettingsControllerProvider.notifier)
          .ensureLoaded();
      await container.read(plexSyncControllerProvider.notifier).sync();
      outcomes.add(container.read(plexSyncControllerProvider));

      // Every typed failure.
      for (final PlexException error in <PlexException>[
        PlexException.unauthorized(),
        PlexException.notReachable(),
        PlexException.notPlex(),
        PlexException.serverError(500),
        PlexException.notFound(),
      ]) {
        container = _container(
          client: FakePlexClient(itemsError: error),
          session: _session,
        );
        await container
            .read(plexSettingsControllerProvider.notifier)
            .ensureLoaded();
        await container.read(plexSyncControllerProvider.notifier).sync();
        outcomes.add(container.read(plexSyncControllerProvider));
      }

      for (final PlexSyncState state in outcomes) {
        expect(state.message, isNotNull);
        expect(state.message, isNot(contains(_token)));
      }
    });
  });
}
