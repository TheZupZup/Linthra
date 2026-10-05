import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/remote_catalog_owner_store.dart';
import 'in_memory_remote_catalog_owner_store.dart';
import 'shared_preferences_remote_catalog_owner_store.dart';

/// Remembers which account each remote catalog slice belongs to (#741).
/// Defaults to in-memory so tests and dev runs need no plugins; the app
/// overrides it with the `shared_preferences` binding below.
final remoteCatalogOwnerStoreProvider =
    Provider<RemoteCatalogOwnerStore>((ref) {
  return InMemoryRemoteCatalogOwnerStore();
});

/// Production binding, applied in `main`; tests keep the in-memory default.
final sharedPreferencesRemoteCatalogOwnerStoreOverride =
    remoteCatalogOwnerStoreProvider.overrideWithValue(
  const SharedPreferencesRemoteCatalogOwnerStore(),
);
