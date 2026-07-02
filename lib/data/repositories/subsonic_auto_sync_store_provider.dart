import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/subsonic_auto_sync_store.dart';
import 'in_memory_subsonic_auto_sync_store.dart';
import 'shared_preferences_subsonic_auto_sync_store.dart';

/// Remembers which Subsonic/Navidrome account has already had its first
/// auto-sync, so onboarding syncs once on a fresh connection without re-pulling
/// on every reconnect of the same account. Defaults to in-memory so tests and
/// dev runs need no plugins; the app overrides it with the `shared_preferences`
/// binding below so the memory survives a restart.
final subsonicAutoSyncStoreProvider = Provider<SubsonicAutoSyncStore>((ref) {
  return InMemorySubsonicAutoSyncStore();
});

/// Production binding: persist the "already auto-synced this account"
/// fingerprint via `shared_preferences` so a reconnect after a restart doesn't
/// trigger an unsolicited full re-sync. Applied in `main`; tests keep the
/// in-memory default.
final sharedPreferencesSubsonicAutoSyncStoreOverride =
    subsonicAutoSyncStoreProvider.overrideWithValue(
  const SharedPreferencesSubsonicAutoSyncStore(),
);
