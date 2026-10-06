import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/local_tag_revision_store.dart';
import 'in_memory_local_tag_revision_store.dart';
import 'shared_preferences_local_tag_revision_store.dart';

/// Which revision of tag reading each local folder was last read in full with.
/// Defaults to in-memory so tests and dev runs need no plugins; the app
/// overrides it with the `shared_preferences` binding below, so a folder isn't
/// read in full again on every launch.
final localTagRevisionStoreProvider = Provider<LocalTagRevisionStore>((ref) {
  return InMemoryLocalTagRevisionStore();
});

/// Production binding: persist the revisions via `shared_preferences`. Applied
/// in `main`; tests keep the in-memory default.
final sharedPreferencesLocalTagRevisionStoreOverride =
    localTagRevisionStoreProvider.overrideWithValue(
  const SharedPreferencesLocalTagRevisionStore(),
);
