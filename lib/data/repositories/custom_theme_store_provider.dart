import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/custom_theme_store.dart';
import 'shared_preferences_custom_theme_store.dart';

/// Storage seam for the optional custom palette.
///
/// The controller treats storage as best-effort, so widget tests that do not
/// install the plugin safely remain on the default palette. Focused tests
/// override this provider with `InMemoryCustomThemeStore`.
final customThemeStoreProvider = Provider<CustomThemeStore>((ref) {
  return const SharedPreferencesCustomThemeStore();
});
