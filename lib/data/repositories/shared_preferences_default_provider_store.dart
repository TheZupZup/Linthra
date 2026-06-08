import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/default_provider_store.dart';

/// A [DefaultProviderStore] backed by `shared_preferences`.
///
/// The explicit default is a single non-secret source id, so one string under
/// one key is plenty — no token, URL, or library content is ever written here.
/// An absent (or empty) value reads as **Automatic** (`null`) rather than
/// throwing, so a storage hiccup can never break library loading or playback.
class SharedPreferencesDefaultProviderStore implements DefaultProviderStore {
  const SharedPreferencesDefaultProviderStore();

  static const String _key = 'default_provider_source_id_v1';

  @override
  Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final String? value = prefs.getString(_key);
    if (value == null || value.isEmpty) return null;
    return value;
  }

  @override
  Future<void> write(String? sourceId) async {
    final prefs = await SharedPreferences.getInstance();
    if (sourceId == null || sourceId.isEmpty) {
      await prefs.remove(_key);
      return;
    }
    await prefs.setString(_key, sourceId);
  }
}
