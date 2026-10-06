import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_account_fingerprint.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
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

import '../../../core/sources/jellyfin/fake_jellyfin_client.dart';
import 'fake_jellyfin_authenticator.dart';

// Signing out and back in to the *same* Jellyfin account mints a new access
// token, so the session the running sync captured is no longer the live one,
// while the account (server + user) is unchanged.

JellyfinSession _alice(String token) => JellyfinSession(
      baseUrl: 'https://music.example.com',
      userId: 'user-1',
      accessToken: token,
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
  test(
      'signing out and back in to the same account while its first sync runs '
      'still syncs its library', () async {
    final InMemoryMusicLibraryRepository catalog =
        InMemoryMusicLibraryRepository();
    final InMemoryJellyfinAutoSyncStore autoSync =
        InMemoryJellyfinAutoSyncStore();
    final FakeJellyfinAuthenticator auth =
        FakeJellyfinAuthenticator(session: _alice('token-1'));
    final FakeJellyfinClient client = FakeJellyfinClient(
      itemsByKind: <JellyfinItemKind, List<JellyfinItemDto>>{
        JellyfinItemKind.audio: <JellyfinItemDto>[_audio('a'), _audio('b')],
      },
    )..itemsGate = Completer<void>();
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        jellyfinAuthenticatorProvider.overrideWithValue(auth),
        jellyfinSessionStoreProvider
            .overrideWithValue(InMemoryJellyfinSessionStore()),
        jellyfinClientProvider.overrideWithValue(client),
        jellyfinAutoSyncStoreProvider.overrideWithValue(autoSync),
        remoteCatalogOwnerStoreProvider
            .overrideWithValue(InMemoryRemoteCatalogOwnerStore()),
        musicLibraryRepositoryProvider.overrideWithValue(catalog),
      ],
    );
    addTearDown(container.dispose);
    final JellyfinSettingsController settings =
        container.read(jellyfinSettingsControllerProvider.notifier);
    await pumpEventQueue();

    Future<void> signIn() async {
      expect(
        await settings.signIn(
          url: 'music.example.com',
          username: 'alice',
          password: 'pw',
        ),
        isTrue,
      );
    }

    // Alice's first auto-sync parks on the library fetch.
    await signIn();
    await pumpEventQueue();
    expect(container.read(jellyfinSyncControllerProvider).isSyncing, isTrue);

    // She signs out and straight back in: same server, same user, a new
    // token.
    await settings.clear();
    auth.session = _alice('token-2');
    await signIn();
    await pumpEventQueue();

    client.itemsGate!.complete();
    await pumpEventQueue(times: 100);

    final List<String> uris = <String>[
      for (final Track t in await catalog.getTracksForSource('jellyfin')) t.uri,
    ];
    expect(
      uris,
      unorderedEquals(<String>['jellyfin:a', 'jellyfin:b']),
      reason: "alice is signed in again, so her library must sync",
    );
    expect(
      container.read(jellyfinSyncControllerProvider).status,
      JellyfinSyncStatus.success,
    );
    expect(await autoSync.read(), jellyfinAccountFingerprint(_alice('x')));
  });
}
