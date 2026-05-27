import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/library_added_store.dart';
import 'in_memory_library_added_store.dart';
import 'shared_preferences_library_added_store.dart';

/// Durable store of when each track first entered the library (the signal
/// behind the "Recently added" smart mix). Defaults to in-memory so tests and
/// dev runs need no plugins; the app overrides it with the `shared_preferences`
/// binding below so timestamps survive a restart.
final libraryAddedStoreProvider = Provider<LibraryAddedStore>((ref) {
  return InMemoryLibraryAddedStore();
});

/// Production binding: persist library-added timestamps via `shared_preferences`
/// so "Recently added" stays meaningful across restarts. Applied in `main`;
/// tests keep the in-memory default.
final sharedPreferencesLibraryAddedStoreOverride =
    libraryAddedStoreProvider.overrideWithValue(
  const SharedPreferencesLibraryAddedStore(),
);
