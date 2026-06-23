import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/app_icon_variant_store.dart';

/// An [AppIconVariantStore] backed by `shared_preferences`.
///
/// The selection is a single non-secret variant id, so one string under one key
/// is plenty — no token, URL, or library content is ever written here. An
/// absent or empty value reads as "no choice" (`null`) rather than throwing, so
/// a storage hiccup falls back to the default (Classic) and never breaks the UI.
class SharedPreferencesAppIconVariantStore implements AppIconVariantStore {
  const SharedPreferencesAppIconVariantStore();

  static const String _key = 'selected_app_icon_variant_v1';

  @override
  Future<String?> read() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? value = prefs.getString(_key);
    if (value == null || value.isEmpty) {
      return null;
    }
    return value;
  }

  @override
  Future<void> write(String? variantId) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (variantId == null || variantId.isEmpty) {
      await prefs.remove(_key);
      return;
    }
    await prefs.setString(_key, variantId);
  }
}
