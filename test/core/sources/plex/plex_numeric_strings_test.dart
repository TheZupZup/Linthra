// A Plex number sent as a string doesn't break the whole listing.
//
// `PlexMediaContainer.fromJson` and `PlexMetadata.fromJson` promise that one
// bad item can't break a whole listing, but they read size / totalSize /
// offset / duration / index / year / leafCount with `as num?`. One track with
// `"duration": "215000"` threw a TypeError out of the parse, which the client
// didn't catch, so:
//  - fetchSectionItems threw a TypeError (not a PlexException) for the whole
//    section;
//  - the sync reported "Something went wrong saving your Plex library" (its
//    catch-all storage message) and never synced that section again while the
//    item was there;
//  - resolving that one track for playback threw a raw TypeError past the
//    resolver's `on PlexException` mapping.
// These fields are now read leniently, as Jellyfin and Subsonic do (#781).
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/plex/http_plex_client.dart';
import 'package:linthra/core/sources/plex/plex_api.dart';
import 'package:linthra/core/sources/plex/plex_client.dart';
import 'package:linthra/core/sources/plex/plex_music_source.dart';
import 'package:linthra/core/sources/plex/plex_playable_uri_resolver.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_plex_session_store.dart';
import 'package:linthra/data/repositories/in_memory_plex_sync_cache_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/plex_session_store_provider.dart';
import 'package:linthra/data/repositories/plex_sync_cache_store_provider.dart';
import 'package:linthra/features/settings/plex/plex_settings_controller.dart';
import 'package:linthra/features/settings/plex/plex_settings_providers.dart';
import 'package:linthra/features/settings/plex/plex_sync_controller.dart';
import 'package:linthra/features/settings/plex/plex_sync_state.dart';

const String _base = 'https://plex.example.com:32400';

const PlexSession _session = PlexSession(
  baseUrl: _base,
  token: 'tok',
  machineIdentifier: 'machine-abc',
  clientIdentifier: 'install-1',
  selectedSectionKeys: <String>['5'],
);

http.Response _container(List<Map<String, dynamic>> metadata) => http.Response(
      jsonEncode(<String, dynamic>{
        'MediaContainer': <String, dynamic>{
          'size': metadata.length,
          'totalSize': metadata.length,
          'offset': 0,
          'Metadata': metadata,
        },
      }),
      200,
      headers: const <String, String>{'content-type': 'application/json'},
    );

/// A section with a good track and one whose duration is a numeric string;
/// the metadata lookup answers the same way for track 102.
HttpPlexClient _client() => HttpPlexClient(
      identity: const PlexClientIdentity(
        clientIdentifier: 'install-1',
        product: 'Linthra',
        version: '0.0.0',
        platform: 'Linux',
        device: 'Test',
      ),
      httpClient: MockClient((http.Request request) async {
        final String path = request.url.path;
        if (path == '/identity') {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'MediaContainer': <String, dynamic>{
                'machineIdentifier': 'machine-abc',
              },
            }),
            200,
          );
        }
        if (path == '/library/metadata/102') {
          return _container(<Map<String, dynamic>>[
            <String, dynamic>{
              'ratingKey': '102',
              'type': 'track',
              'title': 'Dusk',
              'duration': '215000',
              'Media': <dynamic>[
                <String, dynamic>{
                  'Part': <dynamic>[
                    <String, dynamic>{'key': '/library/parts/2/file.flac'},
                  ],
                },
              ],
            },
          ]);
        }
        return _container(<Map<String, dynamic>>[
          <String, dynamic>{
            'ratingKey': '101',
            'type': 'track',
            'title': 'Aurora',
            'duration': 215000,
          },
          <String, dynamic>{
            'ratingKey': '102',
            'type': 'track',
            'title': 'Dusk',
            'duration': '215000',
          },
        ]);
      }),
    );

void main() {
  test('every numeric field reads from a numeric string, or as absent', () {
    final PlexMediaContainer container = PlexMediaContainer.fromJson(
      <String, dynamic>{
        'MediaContainer': <String, dynamic>{
          'size': '2',
          'totalSize': '40',
          'offset': '20',
          'Metadata': <dynamic>[
            <String, dynamic>{
              'ratingKey': '101',
              'duration': '215000',
              'index': '3',
              'year': '1999',
              'leafCount': '12',
              'Media': <dynamic>[
                <String, dynamic>{
                  'Part': <dynamic>[
                    <String, dynamic>{
                      'key': '/library/parts/1/file.flac',
                      'duration': '215000',
                    },
                  ],
                },
              ],
            },
            <String, dynamic>{'ratingKey': '102', 'duration': 'about 3 min'},
          ],
        },
      },
    )!;

    expect(
      (container.size, container.totalSize, container.offset),
      (2, 40, 20),
    );
    final PlexMetadata first = container.metadata.first;
    expect(
      (first.duration, first.index, first.year, first.leafCount),
      (215000, 3, 1999, 12),
    );
    expect(first.media.single.parts.single.duration, 215000);
    expect(container.metadata.last.duration, isNull);
  });

  test('one track with a string duration does not break the section listing',
      () async {
    final List<PlexMetadata> items = await _client().fetchSectionItems(
      baseUrl: _base,
      token: 'tok',
      sectionKey: '5',
      itemType: PlexMetadataType.track,
    );

    expect(items.map((PlexMetadata m) => m.ratingKey), <String>['101', '102']);
  });

  test('one track with a string duration does not fail the whole Plex sync',
      () async {
    final InMemoryMusicLibraryRepository repo =
        InMemoryMusicLibraryRepository();
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        plexClientProvider.overrideWithValue(_client()),
        plexSessionStoreProvider.overrideWithValue(
          InMemoryPlexSessionStore(initialSession: _session),
        ),
        musicLibraryRepositoryProvider.overrideWithValue(repo),
        plexSyncCacheStoreProvider
            .overrideWithValue(InMemoryPlexSyncCacheStore()),
      ],
    );
    addTearDown(container.dispose);
    await container
        .read(plexSettingsControllerProvider.notifier)
        .ensureLoaded();

    await container.read(plexSyncControllerProvider.notifier).sync();

    final PlexSyncState state = container.read(plexSyncControllerProvider);
    expect(state.message, isNot(contains('saving your Plex library')));
    expect(state.status, PlexSyncStatus.done);
  });

  test('a track with a string duration still resolves for playback', () async {
    final PlexPlayableUriResolver resolver = PlexPlayableUriResolver(
      () => PlexMusicSource(session: _session, client: _client()),
    );

    final resolved = await resolver.resolve(
      const Track(id: '102', title: 'Dusk', uri: 'plex:102'),
    );

    expect(resolved.uri.path, '/library/parts/2/file.flac');
  });
}
