// A Plex scan that fails partway writes nothing and prunes nothing.
//
// A sync reads every selected section before it writes. When a later page of
// a section fails, or the second of two selected sections does, the sections
// read so far are only part of the library: written, the prune after them
// would drop every track of the part that wasn't read, and the signature
// saved for them would later make an unchanged re-sync skip the rebuild that
// puts those tracks back. The catalog has to stay as the last good sync left
// it, with no signature recorded for the failed run.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/music_library_repository.dart';
import 'package:linthra/core/repositories/reconciling_catalog_writer.dart';
import 'package:linthra/core/sources/plex/http_plex_client.dart';
import 'package:linthra/core/sources/plex/plex_api.dart';
import 'package:linthra/core/sources/plex/plex_client.dart';
import 'package:linthra/core/sources/plex/plex_endpoints.dart';
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

/// `machineIdentifier` matches [FakePlexClient]'s default identity.
const PlexSession _twoSections = PlexSession(
  baseUrl: 'https://plex.example.com:32400',
  token: 'super-secret-plex-token',
  machineIdentifier: 'fake-machine-id',
  clientIdentifier: 'install-1',
  selectedSectionKeys: <String>['5', '9'],
);

/// What the last good sync left in the catalog: a track the scan would
/// retitle, and one the server no longer lists, which a prune would drop.
const List<Track> _existing = <Track>[
  Track(id: '101', title: 'Old title', uri: 'plex:101'),
  Track(id: 'gone', title: 'Gone', uri: 'plex:gone'),
];

List<String> _rows(List<Track> tracks) =>
    <String>[for (final Track t in tracks) '${t.uri}|${t.title}'];

/// The app's write path (batches upserted over the rows already there, then
/// one prune), counting both.
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
      final int at = stored.indexWhere((Track t) => t.uri == track.uri);
      if (at >= 0) {
        stored[at] = track;
      } else {
        stored.add(track);
      }
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

/// A [FakePlexClient] whose listing of one section fails while the others
/// answer.
class _OneSectionFails extends FakePlexClient {
  _OneSectionFails({
    required this.failingSection,
    required this.failure,
    super.itemsByType,
  });

  final String failingSection;
  final PlexException failure;

  @override
  Future<List<PlexMetadata>> fetchSectionItems({
    required String baseUrl,
    required String token,
    required String sectionKey,
    required PlexMetadataType itemType,
  }) async {
    final List<PlexMetadata> items = await super.fetchSectionItems(
      baseUrl: baseUrl,
      token: token,
      sectionKey: sectionKey,
      itemType: itemType,
    );
    if (sectionKey == failingSection) throw failure;
    return items;
  }
}

/// A real [HttpPlexClient] over a four-track section served two per page,
/// whose second page answers 503.
HttpPlexClient _secondPageFails(List<String?> starts) => HttpPlexClient(
      identity: const PlexClientIdentity(
        clientIdentifier: 'install-1',
        product: 'Linthra',
        version: '0.0.0',
        platform: 'Linux',
        device: 'Test',
      ),
      pageSize: 2,
      httpClient: MockClient((http.Request request) async {
        final String? start =
            request.url.queryParameters[PlexEndpoints.containerStartParam];
        starts.add(start);
        if (start != '0') return http.Response('Service Unavailable', 503);
        return http.Response(
          jsonEncode(<String, dynamic>{
            'MediaContainer': <String, dynamic>{
              'size': 2,
              'totalSize': 4,
              'offset': 0,
              'Metadata': <dynamic>[
                <String, dynamic>{
                  'ratingKey': '101',
                  'type': 'track',
                  'title': 'Aurora',
                },
                <String, dynamic>{
                  'ratingKey': '102',
                  'type': 'track',
                  'title': 'Dusk',
                },
              ],
            },
          }),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      }),
    );

Future<ProviderContainer> _signedIn({
  required PlexClient client,
  required PlexSession session,
  required MusicLibraryRepository repository,
  required InMemoryPlexSyncCacheStore cacheStore,
}) async {
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      plexClientProvider.overrideWithValue(client),
      plexSessionStoreProvider.overrideWithValue(
        InMemoryPlexSessionStore(initialSession: session),
      ),
      musicLibraryRepositoryProvider.overrideWithValue(repository),
      plexSyncCacheStoreProvider.overrideWithValue(cacheStore),
    ],
  );
  addTearDown(container.dispose);
  await container.read(plexSettingsControllerProvider.notifier).ensureLoaded();
  return container;
}

void main() {
  test(
      'the second selected section failing writes nothing, prunes nothing and '
      'saves no signature', () async {
    final _OneSectionFails client = _OneSectionFails(
      failingSection: '9',
      failure: PlexException.serverError(503),
      itemsByType: const <PlexMetadataType, List<PlexMetadata>>{
        PlexMetadataType.track: <PlexMetadata>[
          PlexMetadata(ratingKey: '101', type: 'track', title: 'Aurora'),
          PlexMetadata(ratingKey: '102', type: 'track', title: 'Dusk'),
        ],
      },
    );
    final _ReconcilingRepository repo = _ReconcilingRepository(_existing);
    final InMemoryPlexSyncCacheStore cache = InMemoryPlexSyncCacheStore();
    final ProviderContainer container = await _signedIn(
      client: client,
      session: _twoSections,
      repository: repo,
      cacheStore: cache,
    );

    await container.read(plexSyncControllerProvider.notifier).sync();

    // Section 5 was read in full before section 9 failed.
    expect(
      client.itemRequests.map((r) => r.sectionKey).toList(),
      <String>['5', '9'],
    );
    final PlexSyncState state = container.read(plexSyncControllerProvider);
    expect(state.status, PlexSyncStatus.error);
    expect(repo.upsertBatches, 0);
    expect(repo.pruneCount, 0);
    expect(repo.replaceCount, 0);
    expect(_rows(repo.stored), _rows(_existing));
    expect(await cache.readSignature(_twoSections.machineIdentifier), isNull);
  });

  test(
      'a later page of a section failing writes nothing, prunes nothing and '
      'saves no signature', () async {
    final List<String?> starts = <String?>[];
    final _ReconcilingRepository repo = _ReconcilingRepository(_existing);
    final InMemoryPlexSyncCacheStore cache = InMemoryPlexSyncCacheStore();
    final ProviderContainer container = await _signedIn(
      client: _secondPageFails(starts),
      session: const PlexSession(
        baseUrl: 'https://plex.example.com:32400',
        token: 'super-secret-plex-token',
        machineIdentifier: 'fake-machine-id',
        clientIdentifier: 'install-1',
        selectedSectionKeys: <String>['5'],
      ),
      repository: repo,
      cacheStore: cache,
    );

    await container.read(plexSyncControllerProvider.notifier).sync();

    expect(starts, <String>['0', '2']);
    final PlexSyncState state = container.read(plexSyncControllerProvider);
    expect(state.status, PlexSyncStatus.error);
    expect(repo.upsertBatches, 0);
    expect(repo.pruneCount, 0);
    expect(repo.replaceCount, 0);
    expect(_rows(repo.stored), _rows(_existing));
    expect(await cache.readSignature('fake-machine-id'), isNull);
  });
}
