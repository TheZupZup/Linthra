import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/download_preferences.dart';
import '../../core/repositories/download_repository.dart';
import '../../core/repositories/download_store.dart';
import '../../core/services/connectivity_service.dart';
import '../../core/services/optimistic_connectivity_service.dart';
import 'cache_download_repository.dart';
import 'in_memory_download_preferences.dart';
import 'in_memory_download_store.dart';
import 'shared_preferences_download_preferences.dart';
import 'shared_preferences_download_store.dart';

/// Durable store of which track IDs are cached offline. Defaults to in-memory
/// so tests and dev runs need no plugins; the app overrides it with the
/// `shared_preferences` binding below.
final downloadStoreProvider = Provider<DownloadStore>((ref) {
  return InMemoryDownloadStore();
});

/// The user's "Wi-Fi only" download preference. In-memory by default; the app
/// persists it via `shared_preferences`.
final downloadPreferencesProvider = Provider<DownloadPreferences>((ref) {
  return InMemoryDownloadPreferences();
});

/// Network reachability used to honor the "Wi-Fi only" preference. The default
/// optimistically reports Wi-Fi until real detection lands with remote
/// downloads; tests inject a fake to drive the policy's mobile/offline paths.
final connectivityServiceProvider = Provider<ConnectivityService>((ref) {
  return const OptimisticConnectivityService();
});

/// The single [DownloadRepository] the app drives offline downloads through.
/// It composes the three seams above and centralizes the user-initiated,
/// Wi-Fi-respecting cache policy.
final downloadRepositoryProvider = Provider<DownloadRepository>((ref) {
  final repository = CacheDownloadRepository(
    store: ref.watch(downloadStoreProvider),
    connectivity: ref.watch(connectivityServiceProvider),
    preferences: ref.watch(downloadPreferencesProvider),
  );
  ref.onDispose(repository.dispose);
  return repository;
});

/// Production bindings: persist the cached-ID set and the Wi-Fi-only switch via
/// `shared_preferences` so both survive a restart. Applied in `main`; tests
/// keep the in-memory defaults.
final sharedPreferencesDownloadStoreOverride =
    downloadStoreProvider.overrideWithValue(
  const SharedPreferencesDownloadStore(),
);

final sharedPreferencesDownloadPreferencesOverride =
    downloadPreferencesProvider.overrideWithValue(
  const SharedPreferencesDownloadPreferences(),
);
