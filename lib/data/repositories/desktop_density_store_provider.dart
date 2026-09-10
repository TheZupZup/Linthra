import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/desktop_density.dart';
import '../../core/repositories/desktop_density_store.dart';
import 'in_memory_desktop_density_store.dart';
import 'shared_preferences_desktop_density_store.dart';

/// The single [DesktopDensityStore] the app reads/writes the Compact /
/// Comfortable choice through.
///
/// Defaults to the in-memory implementation so widget and unit tests stay free
/// of platform plugins. The running app overrides this with
/// [sharedPreferencesDesktopDensityStoreOverride] so the choice persists across
/// restarts.
final desktopDensityStoreProvider = Provider<DesktopDensityStore>((ref) {
  return InMemoryDesktopDensityStore();
});

/// Production binding: persists the desktop density via `shared_preferences`.
/// Applied in `main`.
final sharedPreferencesDesktopDensityStoreOverride =
    desktopDensityStoreProvider.overrideWithValue(
  const SharedPreferencesDesktopDensityStore(),
);

/// Reads the stored desktop density before the first frame is built.
///
/// `main` awaits this and seeds `initialDesktopDensityProvider` with the
/// result, for the same reason the theme mode is read there: density decides
/// every row height in the app, and resolving it after startup would draw the
/// library once at one size and immediately relayout it at another.
///
/// Defensive by design: a store that throws (a plugin hiccup, unreadable
/// preferences) resolves to [DesktopDensity.fallback] rather than taking
/// startup down. A display preference must never be able to stop the app
/// booting.
Future<DesktopDensity> readStoredDesktopDensity([
  DesktopDensityStore store = const SharedPreferencesDesktopDensityStore(),
]) async {
  try {
    return await store.read() ?? DesktopDensity.fallback;
  } catch (_) {
    return DesktopDensity.fallback;
  }
}
