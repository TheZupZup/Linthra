import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/preferred_source_store.dart';
import 'in_memory_preferred_source_store.dart';
import 'shared_preferences_preferred_source_store.dart';

/// The single [PreferredSourceStore] the app reads/writes the preferred provider
/// order through.
///
/// Defaults to the in-memory implementation so widget and unit tests stay free
/// of platform plugins. The running app overrides this with
/// [sharedPreferencesPreferredSourceStoreOverride] so the choice persists across
/// restarts.
final preferredSourceStoreProvider = Provider<PreferredSourceStore>((ref) {
  return InMemoryPreferredSourceStore();
});

/// Production binding: persists the preferred provider order via
/// `shared_preferences`. Applied in `main`.
final sharedPreferencesPreferredSourceStoreOverride =
    preferredSourceStoreProvider.overrideWithValue(
  SharedPreferencesPreferredSourceStore(),
);
