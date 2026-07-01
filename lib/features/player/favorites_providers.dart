import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/remote_sync_gateway.dart';
import '../../data/repositories/favorites_repository_provider.dart';
import '../../data/repositories/jellyfin_favorites_gateway.dart';
import '../../data/repositories/subsonic_favorites_gateway.dart';
import '../../data/repositories/synced_favorites_repository.dart';
import '../settings/jellyfin/jellyfin_settings_controller.dart';
import '../settings/jellyfin/jellyfin_settings_providers.dart';
import '../settings/subsonic/subsonic_settings_controller.dart';
import '../settings/subsonic/subsonic_settings_providers.dart';

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

/// Production binding: syncs favourites with the signed-in servers (Jellyfin and
/// Subsonic/Navidrome). Each provider's live client + session are read lazily
/// (mirroring the downloader override), so signing in/out is picked up without
/// rebuilding the repository, and a track's heart mirrors to whichever server
/// owns it. Applied in `main`; tests keep the local-only default.
final remoteFavoritesSyncOverride =
    favoritesRepositoryProvider.overrideWith((ref) {
  final repository = SyncedFavoritesRepository(
    store: ref.watch(favoritesStoreProvider),
    gateways: <RemoteFavoritesGateway>[
      JellyfinFavoritesGateway(
        client: ref.read(jellyfinClientProvider),
        session: () =>
            ref.read(jellyfinSettingsControllerProvider.notifier).session,
      ),
      SubsonicFavoritesGateway(
        client: ref.read(subsonicClientProvider),
        session: () =>
            ref.read(subsonicSettingsControllerProvider.notifier).session,
      ),
    ],
  );
  ref.onDispose(repository.dispose);
  return repository;
});
