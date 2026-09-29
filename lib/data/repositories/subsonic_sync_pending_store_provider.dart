import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/subsonic_sync_pending_store.dart';
import 'in_memory_subsonic_sync_pending_store.dart';
import 'shared_preferences_subsonic_sync_pending_store.dart';

/// Remembers an unfinished Subsonic/Navidrome library sync so launch and resume
/// can pick it up again. Defaults to in-memory so tests and dev runs need no
/// plugins; the app overrides it with the `shared_preferences` binding below.
final subsonicSyncPendingStoreProvider =
    Provider<SubsonicSyncPendingStore>((ref) {
  return InMemorySubsonicSyncPendingStore();
});

/// Production binding: persist the marker via `shared_preferences` so a sync
/// interrupted by the process being killed is retried on the next launch.
/// Applied in `main`; tests keep the in-memory default.
final sharedPreferencesSubsonicSyncPendingStoreOverride =
    subsonicSyncPendingStoreProvider.overrideWithValue(
  const SharedPreferencesSubsonicSyncPendingStore(),
);
