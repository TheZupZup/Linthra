import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/library_song_sort_store.dart';
import 'in_memory_library_song_sort_store.dart';
import 'shared_preferences_library_song_sort_store.dart';

/// The store the Albums grid remembers its order through, apart from the
/// Songs list's.
///
/// In memory by default, so tests stay free of platform plugins; the running
/// app applies [sharedPreferencesLibraryAlbumSortStoreOverride].
final libraryAlbumSortStoreProvider = Provider<LibrarySongSortStore>((ref) {
  return InMemoryLibrarySongSortStore();
});

/// Production binding: persists the Albums order via `shared_preferences`.
/// Applied in `main`.
final sharedPreferencesLibraryAlbumSortStoreOverride =
    libraryAlbumSortStoreProvider.overrideWithValue(
  const SharedPreferencesLibrarySongSortStore(
    key: SharedPreferencesLibrarySongSortStore.albumsKey,
  ),
);
