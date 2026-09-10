import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/desktop_density.dart';
import '../../data/repositories/desktop_density_store_provider.dart';

/// The desktop density the controller starts from on its very first build.
///
/// Defaults to [DesktopDensity.fallback]. `main` overrides it with the value
/// read from storage *before* `runApp`, so the first frame already lays out at
/// the chosen density and the library is not drawn once at one row height and
/// immediately relaid out at another.
///
/// This seam is why the controller has no async load of its own: the value is
/// known before any frame exists, which also removes the race where a stored
/// value lands after the user has already tapped a different option.
final initialDesktopDensityProvider = Provider<DesktopDensity>((ref) {
  return DesktopDensity.fallback;
});

/// Holds the user's Compact / Comfortable choice and persists every change.
///
/// Mirrors [ThemeModeController] deliberately: same seam, same optimistic
/// write, same "a failed preference write never surfaces as an error" rule.
class DesktopDensityController extends Notifier<DesktopDensity> {
  @override
  DesktopDensity build() => ref.read(initialDesktopDensityProvider);

  /// Applies [density] immediately and persists it best-effort.
  ///
  /// The UI relayouts from [state] rather than from the write completing, so
  /// rows resize on tap even if storage is slow or unavailable.
  Future<void> select(DesktopDensity density) async {
    if (density == state) return;
    state = density;
    try {
      await ref.read(desktopDensityStoreProvider).write(density);
    } catch (_) {
      // A failed preference write must never surface as an error or undo the
      // user's visible choice; it just will not survive the next restart.
    }
  }
}

/// The app's desktop density. `LinthraApp` watches this and rebuilds both
/// themes from it, so a change relayouts every screen at once — no restart.
final desktopDensityControllerProvider =
    NotifierProvider<DesktopDensityController, DesktopDensity>(
  DesktopDensityController.new,
);

/// Maps the persisted preference onto Material's [VisualDensity].
///
/// Kept out of the model itself so `DesktopDensity` stays Flutter-free and
/// storable by a plain key/value store.
///
/// Both values are Material's own, not Linthra numbers: Compact is the
/// [VisualDensity.compact] a desktop build already used, Comfortable is
/// [VisualDensity.comfortable], one step back towards the touch layout. Neither
/// touches horizontal padding enough to shrink a control below its minimum tap
/// target — Material's own `IconButton`/`ListTile` minimums still apply on top
/// — which is why the preference is expressed as a density rather than as a
/// second set of spacing constants.
extension DesktopDensityMaterial on DesktopDensity {
  VisualDensity get visualDensity => switch (this) {
        DesktopDensity.compact => VisualDensity.compact,
        DesktopDensity.comfortable => VisualDensity.comfortable,
      };

  /// The user-facing option label.
  String get label => switch (this) {
        DesktopDensity.compact => 'Compact',
        DesktopDensity.comfortable => 'Comfortable',
      };

  /// The icon shown beside [label] in the picker.
  IconData get icon => switch (this) {
        DesktopDensity.compact => Icons.density_small,
        DesktopDensity.comfortable => Icons.density_medium,
      };

  /// The one-line explanation under the picker.
  String get description => switch (this) {
        DesktopDensity.compact =>
          'Tighter rows and grids, so more of your library fits on screen.',
        DesktopDensity.comfortable =>
          'Roomier rows and grids, easier to read and to aim at.',
      };
}
