// #939: signing out of Jellyfin used to keep its whole library, songs that
// could no longer play included, until another account signed in or the
// app's data was cleared. Now the songs downloaded on this device stay, and
// play offline, while the rest leave the library. Signing back in syncs
// again, rather than finding the account already synced.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
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

import '../../../core/sources/jellyfin/fake_jellyfin_client.dart';
import '../../downloads/fake_download_repository.dart';
import 'fake_jellyfin_authenticator.dart';

const JellyfinSession _alice = JellyfinSession(
  baseUrl: 'https://music.example.com',
  userId: 'user-1',
  accessToken: 'token',
  deviceId: 'device-1',
  userName: 'alice',
  serverName: 'Home',
);

JellyfinItemDto _audio(String id) => JellyfinItemDto(
      id: id,
      name: 'Track $id',
      album: 'Album',
      artists: const <String>['Artist'],
      runTimeTicks: 1000000,
      indexNumber: 1,
    );

void main() {
  test('signing out keeps only the songs downloaded here, and back in syncs',
      () async {
    final InMemoryMusicLibraryRepository catalog =
        InMemoryMusicLibraryRepository();
    final InMemoryJellyfinAutoSyncStore autoSync =
        InMemoryJellyfinAutoSyncStore();
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        jellyfinAuthenticatorProvider
            .overrideWithValue(FakeJellyfinAuthenticator(session: _alice)),
        jellyfinSessionStoreProvider
            .overrideWithValue(InMemoryJellyfinSessionStore()),
        jellyfinClientProvider.overrideWithValue(FakeJellyfinClient(
          itemsByKind: <JellyfinItemKind, List<JellyfinItemDto>>{
            JellyfinItemKind.audio: <JellyfinItemDto>[_audio('a'), _audio('b')],
          },
        )),
        jellyfinAutoSyncStoreProvider.overrideWithValue(autoSync),
        remoteCatalogOwnerStoreProvider
            .overrideWithValue(InMemoryRemoteCatalogOwnerStore()),
        musicLibraryRepositoryProvider.overrideWithValue(catalog),
        downloadRepositoryProvider.overrideWithValue(FakeDownloadRepository(
          alreadyDownloaded: <String>{CachedTrack.cacheKeyFor('jellyfin', 'a')},
        )),
      ],
    );
    addTearDown(container.dispose);
    final JellyfinSettingsController settings =
        container.read(jellyfinSettingsControllerProvider.notifier);
    await pumpEventQueue();

    Future<List<String>> library() async => <String>[
          for (final Track t in await catalog.getTracksForSource('jellyfin'))
            t.uri,
        ];
    Future<void> signIn() async {
      expect(
        await settings.signIn(
            url: 'music.example.com', username: 'alice', password: 'pw'),
        isTrue,
      );
      await pumpEventQueue(times: 100);
    }

    await signIn();
    expect(
        await library(), unorderedEquals(<String>['jellyfin:a', 'jellyfin:b']));

    await settings.clear();
    await pumpEventQueue(times: 100);
    expect(await library(), <String>['jellyfin:a'],
        reason: 'only the downloaded song can still play');
    expect(await autoSync.read(), isNull,
        reason: 'signing back in has to sync the library again');

    await signIn();
    expect(
        await library(), unorderedEquals(<String>['jellyfin:a', 'jellyfin:b']));
  });
}
