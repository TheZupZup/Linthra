import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/subsonic/subsonic_account_fingerprint.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_remote_catalog_owner_store.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_auto_sync_store.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_session_store.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_sync_pending_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/remote_catalog_owner_store_provider.dart';
import 'package:linthra/data/repositories/subsonic_auto_sync_store_provider.dart';
import 'package:linthra/data/repositories/subsonic_session_store_provider.dart';
import 'package:linthra/data/repositories/subsonic_sync_pending_store_provider.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_controller.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_providers.dart';
import 'package:linthra/features/settings/subsonic/subsonic_sync_controller.dart';
import 'package:linthra/features/settings/subsonic/subsonic_sync_state.dart';

import '../../../core/sources/subsonic/synthetic_navidrome.dart';

// The Subsonic counterparts of the Jellyfin queue tests in
// jellyfin_auto_sync_test.dart ("a manual Sync while the next account waits
// still records it").

String _account(String user) => subsonicAccountFingerprint(SubsonicSession(
      baseUrl: 'https://music.example.com',
      username: user,
      salt: 'salt',
      token: 'token',
    ));

void main() {
  test('a manual Sync while the next account waits still records it', () async {
    // Signing out leaves the sync card idle, so Sync can be pressed while
    // bob's first auto-sync waits behind alice's. That press must not drop
    // bob's fingerprint: his first sync would go unrecorded and he would walk
    // his whole library again on his next sign-in.
    final SyntheticNavidrome server =
        SyntheticNavidrome(albums: 10, stallAtAlbumCall: 3);
    final InMemorySubsonicAutoSyncStore autoSync =
        InMemorySubsonicAutoSyncStore();
    final InMemoryMusicLibraryRepository catalog =
        InMemoryMusicLibraryRepository();
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        subsonicClientProvider.overrideWithValue(server.client()),
        subsonicSessionStoreProvider
            .overrideWithValue(InMemorySubsonicSessionStore()),
        subsonicAutoSyncStoreProvider.overrideWithValue(autoSync),
        subsonicSyncPendingStoreProvider
            .overrideWithValue(InMemorySubsonicSyncPendingStore()),
        remoteCatalogOwnerStoreProvider
            .overrideWithValue(InMemoryRemoteCatalogOwnerStore()),
        musicLibraryRepositoryProvider.overrideWithValue(catalog),
        subsonicSyncRetryDelaysProvider.overrideWithValue(
          const <Duration>[Duration.zero, Duration.zero],
        ),
      ],
    );
    addTearDown(container.dispose);
    final SubsonicSettingsController settings =
        container.read(subsonicSettingsControllerProvider.notifier);
    await pumpEventQueue();

    Future<void> signIn(String user) async {
      expect(
        await settings.signIn(
          url: 'music.example.com',
          username: user,
          password: 'pw',
        ),
        isTrue,
      );
    }

    // Alice's first auto-sync parks on her third album.
    await signIn('alice');
    await server.stalled;

    await settings.clear();
    await signIn('bob');
    await pumpEventQueue(times: 20);

    // The card is idle (sign-out reset it), so Sync can be pressed.
    expect(
      container.read(subsonicSyncControllerProvider).status,
      SubsonicSyncStatus.idle,
    );
    await container.read(subsonicSyncControllerProvider.notifier).sync();
    server.releaseStall();
    for (int i = 0; i < 200; i++) {
      final SubsonicSyncStatus status =
          container.read(subsonicSyncControllerProvider).status;
      if (status == SubsonicSyncStatus.success ||
          status == SubsonicSyncStatus.error) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await pumpEventQueue(times: 20);

    // Bob's library was synced...
    final Set<String> uris = <String>{
      for (final Track t in await catalog.getTracksForSource('subsonic')) t.uri,
    };
    expect(uris, server.urisFor('bob'));

    // ...so signing out and back in walks nothing again.
    final int albumCallsAfterFirstSync = server.albumCalls;
    await settings.clear();
    await signIn('bob');
    await pumpEventQueue(times: 50);
    for (int i = 0; i < 100; i++) {
      if (!container.read(subsonicSyncControllerProvider).isSyncing) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(
      server.albumCalls,
      albumCallsAfterFirstSync,
      reason: "bob's first sync already ran; signing in again must not walk "
          'his whole library again',
    );
    expect(await autoSync.read(), _account('bob'));
  });
}
