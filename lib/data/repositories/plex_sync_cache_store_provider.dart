import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/plex_sync_cache_store.dart';
import 'in_memory_plex_sync_cache_store.dart';
import 'shared_preferences_plex_sync_cache_store.dart';

/// The single [PlexSyncCacheStore] the Plex sync controller reads/writes the
/// last-synced content signature through.
///
/// Defaults to the in-memory implementation so widget and unit tests stay free
/// of platform plugins (no `shared_preferences`). The running app overrides this
/// with [sharedPreferencesPlexSyncCacheStoreOverride] so the "nothing changed"
/// fast path survives restarts.
final plexSyncCacheStoreProvider = Provider<PlexSyncCacheStore>((ref) {
  return InMemoryPlexSyncCacheStore();
});

/// Production binding: persists the last-synced Plex signature via
/// `shared_preferences`, so a re-sync of an unchanged library after a restart
/// skips rebuilding the catalog. Applied in `main`. Non-secret by construction
/// (see [PlexSyncCacheStore]), so plain key/value storage is appropriate.
final sharedPreferencesPlexSyncCacheStoreOverride =
    plexSyncCacheStoreProvider.overrideWithValue(
  const SharedPreferencesPlexSyncCacheStore(),
);
