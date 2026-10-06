import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/jellyfin/http_jellyfin_client.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_account_fingerprint.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_auto_sync_store.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_session_store.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_remote_catalog_owner_store.dart';
import 'package:linthra/data/repositories/jellyfin_auto_sync_store_provider.dart';
import 'package:linthra/data/repositories/jellyfin_session_store_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/remote_catalog_owner_store_provider.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_providers.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_sync_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_sync_state.dart';

// A Jellyfin library scan on the server removes a track while the sync pages
// through the library. Every track after it moves up one place, and the one
// at the page boundary must not be lost: the sync replaces the catalog with
// what it read, and Jellyfin does not sync again on its own.

const JellyfinSession _alice = JellyfinSession(
  baseUrl: 'https://music.example.com',
  userId: 'user-1',
  accessToken: 'tok',
  deviceId: 'device-1',
  userName: 'alice',
);

Track _track(String id) =>
    Track(id: id, title: 'Track $id', uri: 'jellyfin:$id');

void main() {
  test(
      'a track removed on the server mid-sync does not take a track still '
      'there out of the library', () async {
    // The library alice synced before.
    final List<String> server = <String>['t0', 't1', 't2', 't3', 't4', 't5'];
    final InMemoryMusicLibraryRepository catalog =
        InMemoryMusicLibraryRepository();
    await catalog.upsertCatalog(
      sourceId: 'jellyfin',
      tracks: <Track>[for (final String id in server) _track(id)],
      albums: const <Album>[],
      artists: const <Artist>[],
    );

    int audioPages = 0;
    final MockClient http_ = MockClient((http.Request request) async {
      final Map<String, String> query = request.url.queryParameters;
      List<String> page = const <String>[];
      int total = 0;
      if (query['IncludeItemTypes'] == 'Audio') {
        final int start = int.parse(query['StartIndex'] ?? '0');
        final int limit = int.parse(query['Limit'] ?? '2');
        final int from = start.clamp(0, server.length);
        page = server.sublist(from, (start + limit).clamp(from, server.length));
        total = server.length;
        // A scan removes t0 once the first page has been read.
        if (++audioPages == 1) server.remove('t0');
      }
      return http.Response(
        jsonEncode(<String, dynamic>{
          'Items': <Map<String, dynamic>>[
            for (final String id in page)
              <String, dynamic>{'Id': id, 'Name': 'Track $id'},
          ],
          'TotalRecordCount': total,
        }),
        200,
        headers: const <String, String>{'content-type': 'application/json'},
      );
    });

    final String account = jellyfinAccountFingerprint(_alice);
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        jellyfinSessionStoreProvider.overrideWithValue(
          InMemoryJellyfinSessionStore(initialSession: _alice),
        ),
        jellyfinClientProvider.overrideWithValue(HttpJellyfinClient(
          httpClient: http_,
          itemPageSize: 2,
          retryBackoff: Duration.zero,
          pageGap: Duration.zero,
        )),
        jellyfinAutoSyncStoreProvider
            .overrideWithValue(InMemoryJellyfinAutoSyncStore(account)),
        remoteCatalogOwnerStoreProvider.overrideWithValue(
          InMemoryRemoteCatalogOwnerStore(<String, String>{
            'jellyfin': account,
          }),
        ),
        musicLibraryRepositoryProvider.overrideWithValue(catalog),
      ],
    );
    addTearDown(container.dispose);
    await container
        .read(jellyfinSettingsControllerProvider.notifier)
        .ensureLoaded();

    await container.read(jellyfinSyncControllerProvider.notifier).sync();

    expect(
      container.read(jellyfinSyncControllerProvider).status,
      JellyfinSyncStatus.success,
    );
    final Set<String> uris = <String>{
      for (final Track t in await catalog.getTracksForSource('jellyfin')) t.uri,
    };
    expect(
      uris,
      containsAll(<String>[
        for (final String id in <String>['t1', 't2', 't3', 't4', 't5'])
          'jellyfin:$id',
      ]),
      reason: 't2 never left the server',
    );
  });
}
