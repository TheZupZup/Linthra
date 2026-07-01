import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/playlist_repository.dart';
import '../../core/repositories/playlist_store.dart';
import '../../core/repositories/remote_sync_gateway.dart';
import '../../features/settings/jellyfin/jellyfin_settings_controller.dart';
import '../../features/settings/jellyfin/jellyfin_settings_providers.dart';
import '../../features/settings/subsonic/subsonic_settings_controller.dart';
import '../../features/settings/subsonic/subsonic_settings_providers.dart';
import 'in_memory_playlist_store.dart';
import 'jellyfin_playlist_gateway.dart';
import 'music_library_repository_provider.dart';
import 'shared_preferences_playlist_store.dart';
import 'subsonic_playlist_gateway.dart';
import 'synced_playlist_repository.dart';

/// Durable store of the user's playlists. Defaults to in-memory so tests and dev
/// runs need no plugins; the app overrides it with the `shared_preferences`
/// binding below.
final playlistStoreProvider = Provider<PlaylistStore>((ref) {
  return InMemoryPlaylistStore();
});

/// The app's [PlaylistRepository]. The data-layer default is local-only (no
/// remote gateways) — exactly what tests and offline use need; the composition
/// root overrides it to sync with the signed-in servers (see
/// [remotePlaylistSyncOverride]). Disposed with the scope.
final playlistRepositoryProvider = Provider<PlaylistRepository>((ref) {
  final SyncedPlaylistRepository repository = SyncedPlaylistRepository(
    store: ref.watch(playlistStoreProvider),
    // Resolve legacy bare-id local-playlist membership onto provider uris
    // against the live catalog (unambiguous ids only).
    catalogForMigration: () =>
        ref.read(musicLibraryRepositoryProvider).getAllTracks(),
  );
  ref.onDispose(repository.dispose);
  return repository;
});

/// Production binding: persist playlists via `shared_preferences` so they
/// survive a restart. Applied in `main`; tests keep the in-memory default.
final sharedPreferencesPlaylistStoreOverride =
    playlistStoreProvider.overrideWithValue(
  const SharedPreferencesPlaylistStore(),
);

/// Production binding: sync remote-source playlists with the signed-in servers
/// (Jellyfin and Subsonic/Navidrome). Each provider's live client + session are
/// read lazily (mirroring favourites), so signing in/out is picked up without
/// rebuilding the repository. Applied in `main`; tests keep the local-only
/// default.
final remotePlaylistSyncOverride =
    playlistRepositoryProvider.overrideWith((ref) {
  final SyncedPlaylistRepository repository = SyncedPlaylistRepository(
    store: ref.watch(playlistStoreProvider),
    gateways: <RemotePlaylistGateway>[
      JellyfinPlaylistGateway(
        client: ref.read(jellyfinClientProvider),
        session: () =>
            ref.read(jellyfinSettingsControllerProvider.notifier).session,
      ),
      SubsonicPlaylistGateway(
        client: ref.read(subsonicClientProvider),
        session: () =>
            ref.read(subsonicSettingsControllerProvider.notifier).session,
      ),
    ],
    catalogForMigration: () =>
        ref.read(musicLibraryRepositoryProvider).getAllTracks(),
  );
  ref.onDispose(repository.dispose);
  return repository;
});
