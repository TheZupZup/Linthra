import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/favorites_repository.dart';
import '../../core/repositories/favorites_store.dart';
import 'in_memory_favorites_store.dart';
import 'shared_preferences_favorites_store.dart';
import 'synced_favorites_repository.dart';

/// Durable store of the user's favourite track ids. Defaults to in-memory so
/// tests and dev runs need no plugins; the app overrides it with the
/// `shared_preferences` binding below.
final favoritesStoreProvider = Provider<FavoritesStore>((ref) {
  return InMemoryFavoritesStore();
});

/// The app's [FavoritesRepository]. The data-layer default is local-only (no
/// remote gateways) — exactly what tests and offline use need; the composition
/// root overrides it to sync with the signed-in servers (see
/// `remoteFavoritesSyncOverride`). Disposed with the scope.
final favoritesRepositoryProvider = Provider<FavoritesRepository>((ref) {
  final repository = SyncedFavoritesRepository(
    store: ref.watch(favoritesStoreProvider),
  );
  ref.onDispose(repository.dispose);
  return repository;
});

/// Production binding: persist favourites via `shared_preferences` so they
/// survive a restart. Applied in `main`; tests keep the in-memory default.
final sharedPreferencesFavoritesStoreOverride =
    favoritesStoreProvider.overrideWithValue(
  const SharedPreferencesFavoritesStore(),
);
