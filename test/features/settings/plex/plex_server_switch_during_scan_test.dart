// A Plex scan that finishes after the app moved to another server writes
// nothing.
//
// The sync's "still current" check compares two things: whether the synced
// rows were removed since the scan started (the catalog generation), and
// whether the server connected now is the one scanned (its
// machineIdentifier). The disconnect and connect flows bump the generation,
// so the existing tests can't tell whether the server comparison does
// anything. Here the live source moves to another machine and nothing
// removes the catalog, so only that comparison stands between the old
// server's ratingKeys and the new server's slice. Written, `plex:<ratingKey>`
// rows would name whatever those numbers are on the new machine, and the
// saved signature would describe a server that is no longer connected.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/music_library_repository.dart';
import 'package:linthra/core/repositories/reconciling_catalog_writer.dart';
import 'package:linthra/core/sources/plex/plex_api.dart';
import 'package:linthra/core/sources/plex/plex_music_source.dart';
import 'package:linthra/data/repositories/in_memory_plex_sync_cache_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/plex_sync_cache_store_provider.dart';
import 'package:linthra/features/settings/plex/plex_settings_controller.dart';
import 'package:linthra/features/settings/plex/plex_sync_controller.dart';
import 'package:linthra/features/settings/plex/plex_sync_state.dart';

import '../../../core/sources/plex/fake_plex_client.dart';

const PlexSession _home = PlexSession(
  baseUrl: 'https://plex.example.com:32400',
  token: 'super-secret-plex-token',
  machineIdentifier: 'fake-machine-id',
  clientIdentifier: 'install-1',
  selectedSectionKeys: <String>['5'],
);

/// Another server, with a section of the same key selected.
const PlexSession _other = PlexSession(
  baseUrl: 'https://other.example.com:32400',
  token: 'another-plex-token',
  machineIdentifier: 'other-machine',
  clientIdentifier: 'install-1',
  selectedSectionKeys: <String>['5'],
);

const List<Track> _existing = <Track>[
  Track(id: 'r0', title: 'Old 0', uri: 'plex:r0'),
  Track(id: 'r1', title: 'Old 1', uri: 'plex:r1'),
];

/// A [FakePlexClient] whose listings wait for [gate], and say through
/// [reached] that the scan got that far.
class _GatedPlexClient extends FakePlexClient {
  _GatedPlexClient({super.itemsByType});

  final Completer<void> gate = Completer<void>();
  final Completer<void> reached = Completer<void>();

  @override
  Future<List<PlexMetadata>> fetchSectionItems({
    required String baseUrl,
    required String token,
    required String sectionKey,
    required PlexMetadataType itemType,
  }) async {
    if (!reached.isCompleted) reached.complete();
    await gate.future;
    return super.fetchSectionItems(
      baseUrl: baseUrl,
      token: token,
      sectionKey: sectionKey,
      itemType: itemType,
    );
  }
}

/// The app's write path, counting upserts and prunes.
class _ReconcilingRepository
    implements MusicLibraryRepository, ReconcilingCatalogWriter {
  _ReconcilingRepository(List<Track> existing) {
    stored.addAll(existing);
  }

  final List<Track> stored = <Track>[];
  int upsertBatches = 0;
  int pruneCount = 0;
  int replaceCount = 0;

  @override
  Future<void> upsertTracks({
    required String sourceId,
    required List<Track> tracks,
  }) async {
    upsertBatches++;
    for (final Track track in tracks) {
      stored
        ..removeWhere((Track t) => t.uri == track.uri)
        ..add(track);
    }
  }

  @override
  Future<List<String>> removeTracksNotIn({
    required String sourceId,
    required Set<String> keepUris,
  }) async {
    pruneCount++;
    final List<String> removed = <String>[
      for (final Track t in stored)
        if (!keepUris.contains(t.uri)) t.uri,
    ];
    stored.removeWhere((Track t) => !keepUris.contains(t.uri));
    return removed;
  }

  @override
  Future<void> upsertCatalog({
    required String sourceId,
    required List<Track> tracks,
    required List<Album> albums,
    required List<Artist> artists,
  }) async {
    replaceCount++;
    stored
      ..clear()
      ..addAll(tracks);
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

List<Override> _overrides({
  required PlexMusicSource source,
  required MusicLibraryRepository repository,
  required InMemoryPlexSyncCacheStore cacheStore,
}) =>
    <Override>[
      plexMusicSourceProvider.overrideWithValue(source),
      musicLibraryRepositoryProvider.overrideWithValue(repository),
      plexSyncCacheStoreProvider.overrideWithValue(cacheStore),
    ];

void main() {
  test(
      'a scan that finishes after a switch to another server writes nothing '
      'and saves no signature', () async {
    final _GatedPlexClient client = _GatedPlexClient(
      itemsByType: const <PlexMetadataType, List<PlexMetadata>>{
        PlexMetadataType.track: <PlexMetadata>[
          PlexMetadata(ratingKey: '101', type: 'track', title: 'Aurora'),
          PlexMetadata(ratingKey: '102', type: 'track', title: 'Dusk'),
        ],
      },
    );
    final _ReconcilingRepository repo = _ReconcilingRepository(_existing);
    final InMemoryPlexSyncCacheStore cache = InMemoryPlexSyncCacheStore();
    final ProviderContainer container = ProviderContainer(
      overrides: _overrides(
        source: PlexMusicSource(session: _home, client: client),
        repository: repo,
        cacheStore: cache,
      ),
    );
    addTearDown(container.dispose);

    final Future<void> syncing =
        container.read(plexSyncControllerProvider.notifier).sync();
    await client.reached.future;
    expect(container.read(plexSyncControllerProvider).isScanning, isTrue);

    // The live source is now another machine's. Nothing removed the synced
    // rows, so the catalog generation the scan started at still holds.
    container.updateOverrides(_overrides(
      source: PlexMusicSource(session: _other, client: client),
      repository: repo,
      cacheStore: cache,
    ));
    client.gate.complete();
    await syncing;

    expect(repo.upsertBatches, 0);
    expect(repo.pruneCount, 0);
    expect(repo.replaceCount, 0);
    expect(repo.stored.map((Track t) => t.uri), <String>['plex:r0', 'plex:r1']);
    expect(await cache.readSignature(_home.machineIdentifier), isNull);
    expect(await cache.readSignature(_other.machineIdentifier), isNull);
    // Dropped quietly: not "done" for a library that was never written, and
    // not an error on the new server's card.
    expect(
        container.read(plexSyncControllerProvider).status, PlexSyncStatus.idle);
  });
}
