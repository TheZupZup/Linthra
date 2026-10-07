import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/pending_track_move_store.dart';
import 'in_memory_pending_track_move_store.dart';
import 'shared_preferences_pending_track_move_store.dart';

/// Where local moves some store could not take wait for the next scan.
/// Defaults to in-memory so tests and dev runs need no plugins; the app
/// overrides it with the `shared_preferences` binding below, since a kept move
/// has to survive a restart.
final pendingTrackMoveStoreProvider = Provider<PendingTrackMoveStore>((ref) {
  return InMemoryPendingTrackMoveStore();
});

/// Production binding. Applied in `main`; tests keep the in-memory default.
final sharedPreferencesPendingTrackMoveStoreOverride =
    pendingTrackMoveStoreProvider.overrideWithValue(
  const SharedPreferencesPendingTrackMoveStore(),
);
