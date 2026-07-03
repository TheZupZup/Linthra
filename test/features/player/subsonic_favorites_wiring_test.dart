import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/favorites_repository_provider.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_session_store.dart';
import 'package:linthra/data/repositories/subsonic_session_store_provider.dart';
import 'package:linthra/features/player/favorites_providers.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_controller.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_providers.dart';

import '../../core/sources/subsonic/fake_subsonic_client.dart';

const _session = SubsonicSession(
  baseUrl: 'https://nav.example.com',
  username: 'alice',
  salt: 'salt1',
  token: 'tok1',
);

void main() {
  // Exercises the real production favourites override end to end, so a wiring
  // regression (heart not reaching the Subsonic gateway) is caught here rather
  // than only on a device.
  test('production favourites override stars a Subsonic track on the server',
      () async {
    final fake = FakeSubsonicClient();
    final container = ProviderContainer(
      overrides: <Override>[
        remoteFavoritesSyncOverride,
        subsonicClientProvider.overrideWithValue(fake),
        subsonicSessionStoreProvider.overrideWithValue(
          InMemorySubsonicSessionStore(initialSession: _session),
        ),
      ],
    );
    addTearDown(container.dispose);

    // Load the persisted Subsonic session so the controller reports connected —
    // exactly what `main` awaits at startup.
    await container
        .read(subsonicSettingsControllerProvider.notifier)
        .ensureLoaded();

    final repo = container.read(favoritesRepositoryProvider);
    await repo.setFavorite(
      const Track(id: 'mf-1', title: 'One', uri: 'subsonic:mf-1'),
      true,
    );
    expect(fake.starCalls,
        <({String songId, bool starred})>[(songId: 'mf-1', starred: true)]);

    await repo.setFavorite(
      const Track(id: 'mf-1', title: 'One', uri: 'subsonic:mf-1'),
      false,
    );
    expect(fake.starCalls.last, (songId: 'mf-1', starred: false));
  });
}
