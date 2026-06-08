import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/playback_source_strategy_store.dart';

/// A [PlaybackSourceStrategyStore] backed by `shared_preferences`.
///
/// The strategy is a single non-secret enum name, so one string under one key is
/// plenty — no token, URL, or library content is ever written here. An absent
/// (or empty) value reads as the default strategy (`null`) rather than throwing,
/// so a storage hiccup can never break playback.
class SharedPreferencesPlaybackSourceStrategyStore
    implements PlaybackSourceStrategyStore {
  const SharedPreferencesPlaybackSourceStrategyStore();

  static const String _key = 'playback_source_strategy_v1';

  @override
  Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final String? value = prefs.getString(_key);
    if (value == null || value.isEmpty) return null;
    return value;
  }

  @override
  Future<void> write(String? strategyName) async {
    final prefs = await SharedPreferences.getInstance();
    if (strategyName == null || strategyName.isEmpty) {
      await prefs.remove(_key);
      return;
    }
    await prefs.setString(_key, strategyName);
  }
}
