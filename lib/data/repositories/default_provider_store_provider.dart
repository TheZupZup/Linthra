import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/default_provider_store.dart';
import 'in_memory_default_provider_store.dart';
import 'shared_preferences_default_provider_store.dart';

/// The single [DefaultProviderStore] the app reads/writes the explicit default
/// provider through.
///
/// Defaults to the in-memory implementation so widget and unit tests stay free
/// of platform plugins. The running app overrides this with
/// [sharedPreferencesDefaultProviderStoreOverride] so the choice persists across
/// restarts.
final defaultProviderStoreProvider = Provider<DefaultProviderStore>((ref) {
  return InMemoryDefaultProviderStore();
});

/// Production binding: persists the explicit default provider via
/// `shared_preferences`. Applied in `main`.
final sharedPreferencesDefaultProviderStoreOverride =
    defaultProviderStoreProvider.overrideWithValue(
  const SharedPreferencesDefaultProviderStore(),
);
