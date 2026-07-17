import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/custom_theme_settings.dart';
import '../../core/repositories/custom_theme_store.dart';

/// Persists the custom palette as three non-secret primitive values.
class SharedPreferencesCustomThemeStore implements CustomThemeStore {
  const SharedPreferencesCustomThemeStore();

  static const String _enabledKey = 'custom_theme_enabled_v1';
  static const String _primaryKey = 'custom_theme_primary_v1';
  static const String _accentKey = 'custom_theme_accent_v1';

  @override
  Future<CustomThemeSettings?> read() async {
    final SharedPreferences preferences =
        await SharedPreferences.getInstance();
    if (!preferences.containsKey(_enabledKey) &&
        !preferences.containsKey(_primaryKey) &&
        !preferences.containsKey(_accentKey)) {
      return null;
    }

    return CustomThemeSettings(
      enabled: preferences.getBool(_enabledKey) ?? false,
      primaryColorValue: preferences.getInt(_primaryKey) ??
          CustomThemeSettings.defaultPrimaryColorValue,
      accentColorValue: preferences.getInt(_accentKey) ??
          CustomThemeSettings.defaultAccentColorValue,
    );
  }

  @override
  Future<void> write(CustomThemeSettings? settings) async {
    final SharedPreferences preferences =
        await SharedPreferences.getInstance();
    if (settings == null) {
      await Future.wait(<Future<bool>>[
        preferences.remove(_enabledKey),
        preferences.remove(_primaryKey),
        preferences.remove(_accentKey),
      ]);
      return;
    }

    await Future.wait(<Future<bool>>[
      preferences.setBool(_enabledKey, settings.enabled),
      preferences.setInt(_primaryKey, settings.primaryColorValue),
      preferences.setInt(_accentKey, settings.accentColorValue),
    ]);
  }
}
