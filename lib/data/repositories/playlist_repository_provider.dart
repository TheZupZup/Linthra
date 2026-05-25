import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/playlist_repository.dart';
import '../../core/repositories/playlist_store.dart';
import '../../features/settings/jellyfin/jellyfin_settings_controller.dart';
import '../../features/settings/jellyfin/jellyfin_settings_providers.dart';
import 'in_memory_playlist_store.dart';
import 'shared_preferences_playlist_store.dart';
import 'synced_playlist_repository.dart';

/// Durable store of the user's playlists. Defaults to in-memory so tests and dev
/// runs need no plugins; the app overrides it with the `shared_preferences`
/// binding below.
final playlistStoreProvider = Provider<PlaylistStore>((ref) {
  return InMemoryPlaylistStore();
});

/// The app's [PlaylistRepository]. The data-layer default is local-only (no
/// Jellyfin client or session) — exactly what tests and offline use need; the
/// composition root overrides it to sync with the signed-in server (see
/// [jellyfinPlaylistSyncOverride]). Disposed with the scope.
final playlistRepositoryProvider = Provider<PlaylistRepository>((ref) {
  final SyncedPlaylistRepository repository = SyncedPlaylistRepository(
    store: ref.watch(playlistStoreProvider),
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

/// Production binding: sync Jellyfin-source playlists with the signed-in server.
/// Reads the live client + session lazily (mirroring favourites), so signing
/// in/out is picked up without rebuilding the repository. Applied in `main`;
/// tests keep the local-only default.
final jellyfinPlaylistSyncOverride =
    playlistRepositoryProvider.overrideWith((ref) {
  final SyncedPlaylistRepository repository = SyncedPlaylistRepository(
    store: ref.watch(playlistStoreProvider),
    client: ref.read(jellyfinClientProvider),
    session: () =>
        ref.read(jellyfinSettingsControllerProvider.notifier).session,
  );
  ref.onDispose(repository.dispose);
  return repository;
});
