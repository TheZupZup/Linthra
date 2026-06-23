import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/app_icon_variant_store.dart';
import 'in_memory_app_icon_variant_store.dart';
import 'shared_preferences_app_icon_variant_store.dart';

/// The single [AppIconVariantStore] the app reads/writes the selected branding
/// variant through.
///
/// Defaults to the in-memory implementation so widget and unit tests stay free
/// of platform plugins. The running app overrides this with
/// [sharedPreferencesAppIconVariantStoreOverride] so the choice persists across
/// restarts.
final appIconVariantStoreProvider = Provider<AppIconVariantStore>((ref) {
  return InMemoryAppIconVariantStore();
});

/// Production binding: persists the selected variant via `shared_preferences`.
/// Applied in `main`.
final sharedPreferencesAppIconVariantStoreOverride =
    appIconVariantStoreProvider.overrideWithValue(
  const SharedPreferencesAppIconVariantStore(),
);
