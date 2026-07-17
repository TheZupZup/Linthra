import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/app_icon_variant_store_provider.dart';
import '../../data/repositories/launcher_icon_service_provider.dart';
import '../support/support_actions_provider.dart';
import 'app_icon_access.dart';
import 'app_icon_variant.dart';

/// Holds the user's selected app-icon / branding variant, defaulting to
/// [AppIconVariants.classic].
///
/// The choice is loaded from the [appIconVariantStoreProvider] store at startup
/// and persisted on every change, so it survives a restart. Until the async
/// load lands the controller serves Classic, and an unknown, absent, or
/// unavailable stored id resolves to Classic — so the mark always has a valid
/// look and a storage hiccup can never break the UI.
class AppIconController extends Notifier<AppIconVariant> {
  bool _loadStarted = false;

  @override
  AppIconVariant build() {
    if (!_loadStarted) {
      _loadStarted = true;
      _load();
    }
    return AppIconVariants.classic;
  }

  Future<void> _load() async {
    AppIconVariant resolved = AppIconVariants.classic;
    try {
      final String? stored = await ref.read(appIconVariantStoreProvider).read();
      final AppIconVariant storedVariant = AppIconVariants.byId(stored);
      final AppIconAccess access = ref.read(appIconAccessProvider(storedVariant));
      resolved = access.canSelect ? storedVariant : AppIconVariants.classic;

      if (resolved.id != storedVariant.id) {
        await ref.read(appIconVariantStoreProvider).write(resolved.id);
      }
      if (resolved.id != state.id) {
        state = resolved;
      }
    } catch (_) {
      // A storage hiccup must never break the UI; keep Classic.
    }
    // Re-assert the launcher icon for the restored choice on every cold start,
    // so it survives a restart (and an OS that reset the alias). The native
    // side only flips aliases whose state differs, so this is a no-op — and
    // causes no launcher refresh — when the icon is already correct.
    await _applyLauncherIcon(resolved.id);
  }

  /// Selects [variant], persists it, and switches the real launcher icon to
  /// match (Android only).
  ///
  /// Returns `false` when the style is an unavailable supporter cosmetic, and
  /// `true` when the selection is already active or was applied successfully.
  Future<bool> select(AppIconVariant variant) async {
    if (!ref.read(appIconAccessProvider(variant)).canSelect) {
      return false;
    }
    if (variant.id == state.id) {
      return true;
    }
    state = variant;
    try {
      await ref.read(appIconVariantStoreProvider).write(variant.id);
    } catch (_) {
      // Best-effort persistence: the in-memory choice still applies this session.
    }
    await _applyLauncherIcon(variant.id);
    return true;
  }

  /// Switches the device launcher icon to [variantId]'s alias, best-effort.
  ///
  /// Launcher switching is Android-only and best-effort: a failure, or a
  /// platform/device without runtime switching, must never break the in-app
  /// selection — which has already been applied and persisted above.
  Future<void> _applyLauncherIcon(String variantId) async {
    try {
      await ref.read(launcherIconServiceProvider).applyVariant(variantId);
    } catch (_) {
      // Ignored on purpose; the in-app branding choice still stands.
    }
  }
}

/// The user's selected branding variant. The Appearance screen reads and writes
/// this; the in-app mark watches it so About and the Settings header reflect the
/// choice immediately.
final appIconControllerProvider =
    NotifierProvider<AppIconController, AppIconVariant>(
  AppIconController.new,
);

/// The branding variants displayed for [distribution].
///
/// Every channel receives the complete catalog so supporter styles can be
/// previewed consistently. Selection access is enforced separately by
/// [appIconAccessProvider]. F-Droid includes every style; a Play-only billing
/// integration can lock only [AppIconTier.supporter] cosmetics.
List<AppIconVariant> appIconVariantsFor(SupportDistribution distribution) {
  return AppIconVariants.all;
}

/// The branding variants displayed in this build, read by the Appearance
/// screen. Access and selection are deliberately separate concerns.
final availableAppIconVariantsProvider = Provider<List<AppIconVariant>>(
  (ref) => appIconVariantsFor(ref.watch(supportDistributionProvider)),
);
