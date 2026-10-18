import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/library_song_sort_store.dart';
import 'in_memory_library_song_sort_store.dart';
import 'shared_preferences_library_song_sort_store.dart';

/// The single [LibrarySongSortStore] the Songs list remembers its order
/// through.
///
/// Defaults to the in-memory implementation so widget and unit tests stay free
/// of platform plugins. The running app overrides this with
/// [sharedPreferencesLibrarySongSortStoreOverride] so the choice survives a
/// restart.
final librarySongSortStoreProvider = Provider<LibrarySongSortStore>((ref) {
  return InMemoryLibrarySongSortStore();
});

/// Production binding: persists the Songs order via `shared_preferences`.
/// Applied in `main`.
final sharedPreferencesLibrarySongSortStoreOverride =
    librarySongSortStoreProvider.overrideWithValue(
  const SharedPreferencesLibrarySongSortStore(),
);
