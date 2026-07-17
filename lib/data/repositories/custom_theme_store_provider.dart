import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/custom_theme_store.dart';
import 'in_memory_custom_theme_store.dart';
import 'shared_preferences_custom_theme_store.dart';

/// Storage seam for the optional custom palette.
final customThemeStoreProvider = Provider<CustomThemeStore>((ref) {
  return InMemoryCustomThemeStore();
});

/// Production binding applied in `main`.
final sharedPreferencesCustomThemeStoreOverride =
    customThemeStoreProvider.overrideWithValue(
  const SharedPreferencesCustomThemeStore(),
);
