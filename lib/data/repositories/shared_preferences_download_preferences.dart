import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/cache_size.dart';
import '../../core/repositories/download_preferences.dart';

/// A [DownloadPreferences] backed by `shared_preferences`. Both choices are
/// small scalars (a bool and an int), so they live next to the other small user
/// choices in the key/value store rather than in the SQLite catalog.
class SharedPreferencesDownloadPreferences implements DownloadPreferences {
  const SharedPreferencesDownloadPreferences();

  static const String _wifiOnlyKey = 'downloads_wifi_only';
  static const String _maxCacheBytesKey = 'downloads_max_cache_bytes';

  @override
  Future<bool> wifiOnly() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_wifiOnlyKey) ?? false;
  }

  @override
  Future<void> setWifiOnly(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_wifiOnlyKey, value);
  }

  @override
  Future<int> maxCacheBytes() async {
    final prefs = await SharedPreferences.getInstance();
    final int? stored = prefs.getInt(_maxCacheBytesKey);
    if (stored == null) return CacheSize.defaultLimit;
    return CacheSize.clamp(stored);
  }

  @override
  Future<void> setMaxCacheBytes(int bytes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_maxCacheBytesKey, CacheSize.clamp(bytes));
  }
}
