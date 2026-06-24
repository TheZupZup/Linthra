import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/app_icon_variant_store_provider.dart';
import '../../data/repositories/launcher_icon_service_provider.dart';
import '../support/support_actions_provider.dart';
import 'app_icon_variant.dart';

/// Holds the user's selected app-icon / branding variant, defaulting to
/// [AppIconVariants.classic].
///
/// The choice is loaded from the [appIconVariantStoreProvider] store at startup
/// and persisted on every change, so it survives a restart. Until the async
/// load lands the controller serves Classic, and an unknown or absent stored id
/// resolves to Classic too (via [AppIconVariants.byId]) — so the mark always has
/// a valid look and a storage hiccup can never break the UI.
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
      resolved = AppIconVariants.byId(stored);
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
  /// match (Android only). A no-op when nothing changes.
  Future<void> select(AppIconVariant variant) async {
    if (variant.id == state.id) {
      return;
    }
    state = variant;
    try {
      await ref.read(appIconVariantStoreProvider).write(variant.id);
    } catch (_) {
      // Best-effort persistence: the in-memory choice still applies this session.
    }
    await _applyLauncherIcon(variant.id);
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

/// The branding variants offered for [distribution].
///
/// Foundation PR: every variant is offered and selectable on every channel,
/// F-Droid included, so this returns the full catalog unchanged. The
/// [AppIconVariant.tier] field together with [distribution] is the seam a
/// future, Play-only PR uses to present supporter-tier styles as cosmetic
/// rewards — purely cosmetic, never gating playback, cache, providers, Android
/// Auto, or any core feature, and F-Droid always keeps every variant available.
List<AppIconVariant> appIconVariantsFor(SupportDistribution distribution) {
  return AppIconVariants.all;
}

/// The branding variants offered in this build, read by the Appearance screen.
///
/// Declared as a provider so a future build can override the set without
/// touching the screen, and so widget tests can inject a fixed list. Mirrors the
/// `supportActionsProvider` seam from the Support feature.
final availableAppIconVariantsProvider = Provider<List<AppIconVariant>>(
  (ref) => appIconVariantsFor(SupportDistribution.current),
);
