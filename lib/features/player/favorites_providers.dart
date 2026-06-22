import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/favorites_repository_provider.dart';
import '../../data/repositories/jellyfin_synced_favorites_repository.dart';
import '../settings/jellyfin/jellyfin_settings_controller.dart';
import '../settings/jellyfin/jellyfin_settings_providers.dart';

/// Streams the favourite track-uri set for the UI. Entries are
/// provider-namespaced [Track.uri]s, so `jellyfin:101` and `subsonic:101` are
/// tracked independently.
final favoriteIdsProvider = StreamProvider<Set<String>>((ref) {
  return ref.watch(favoritesRepositoryProvider).favoritesStream;
});

/// Whether a single track is currently a favourite — for the heart toggle. It
/// recomputes whenever the favourites set changes, so the icon stays live.
/// Keyed by the provider-namespaced [Track.uri], not the bare id.
final isFavoriteProvider = Provider.family<bool, String>((ref, trackUri) {
  final Set<String> ids =
      ref.watch(favoriteIdsProvider).valueOrNull ?? const <String>{};
  return ids.contains(trackUri);
});

/// Production binding: syncs favourites with the signed-in Jellyfin server.
/// Reads the live client + session lazily (mirroring the downloader override),
/// so signing in/out is picked up without rebuilding the repository. Applied in
/// `main`; tests keep the local-only default.
final jellyfinFavoritesOverride =
    favoritesRepositoryProvider.overrideWith((ref) {
  final repository = JellyfinSyncedFavoritesRepository(
    store: ref.watch(favoritesStoreProvider),
    client: ref.read(jellyfinClientProvider),
    session: () =>
        ref.read(jellyfinSettingsControllerProvider.notifier).session,
  );
  ref.onDispose(repository.dispose);
  return repository;
});
