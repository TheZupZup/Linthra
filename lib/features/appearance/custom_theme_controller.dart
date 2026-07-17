import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/custom_theme_settings.dart';
import '../../data/repositories/custom_theme_store_provider.dart';
import '../support/supporter_entitlement.dart';

/// Loads and persists Linthra's optional custom color palette.
class CustomThemeController extends Notifier<CustomThemeSettings> {
  bool _loadStarted = false;

  @override
  CustomThemeSettings build() {
    if (!_loadStarted) {
      _loadStarted = true;
      _load();
    }
    return CustomThemeSettings.defaults;
  }

  Future<void> _load() async {
    try {
      final CustomThemeSettings? stored =
          await ref.read(customThemeStoreProvider).read();
      if (stored != null) {
        state = stored;
      }
    } catch (_) {
      // A preference read must never prevent Linthra from starting.
    }
  }

  Future<bool> setEnabled(bool enabled) async {
    if (!_canEdit) {
      return false;
    }
    await _setState(state.copyWith(enabled: enabled));
    return true;
  }

  Future<bool> setPrimaryColor(int colorValue) async {
    if (!_canEdit) {
      return false;
    }
    await _setState(state.copyWith(primaryColorValue: colorValue));
    return true;
  }

  Future<bool> setAccentColor(int colorValue) async {
    if (!_canEdit) {
      return false;
    }
    await _setState(state.copyWith(accentColorValue: colorValue));
    return true;
  }

  Future<bool> reset() async {
    if (!_canEdit) {
      return false;
    }
    await _setState(CustomThemeSettings.defaults);
    return true;
  }

  bool get _canEdit =>
      ref.read(supporterEntitlementProvider).allowsCosmetics;

  Future<void> _setState(CustomThemeSettings next) async {
    if (next == state) {
      return;
    }
    state = next;
    try {
      await ref.read(customThemeStoreProvider).write(next);
    } catch (_) {
      // The current session still reflects the choice when persistence fails.
    }
  }
}

final customThemeControllerProvider =
    NotifierProvider<CustomThemeController, CustomThemeSettings>(
  CustomThemeController.new,
);
