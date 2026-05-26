import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/cache_size.dart';
import '../../core/repositories/download_preferences.dart';

/// A [DownloadPreferences] backed by `shared_preferences`. Both choices are
/// small scalars (a bool and an int), so they live next to the other small user
/// choices in the key/value store rather than in the SQLite catalog.
class SharedPreferencesDownloadPreferences implements DownloadPreferences {
  const SharedPreferencesDownloadPreferences();

  static const String _allowMobileDataKey = 'downloads_allow_mobile_data';
  static const String _maxCacheBytesKey = 'downloads_max_cache_bytes';
  static const String _preloadEnabledKey = 'downloads_preload_enabled';
  static const String _precacheCountKey = 'downloads_precache_count';

  @override
  Future<bool> allowMobileData() async {
    final prefs = await SharedPreferences.getInstance();
    // Default false: Wi-Fi only is the safe out-of-the-box behaviour.
    return prefs.getBool(_allowMobileDataKey) ?? false;
  }

  @override
  Future<void> setAllowMobileData(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_allowMobileDataKey, value);
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

  @override
  Future<bool> preloadEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_preloadEnabledKey) ?? true;
  }

  @override
  Future<void> setPreloadEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_preloadEnabledKey, value);
  }

  @override
  Future<int> precacheCount() async {
    final prefs = await SharedPreferences.getInstance();
    final int? stored = prefs.getInt(_precacheCountKey);
    if (stored == null) return kDefaultPrecacheCount;
    return sanitizePrecacheCount(stored);
  }

  @override
  Future<void> setPrecacheCount(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_precacheCountKey, sanitizePrecacheCount(value));
  }
}
