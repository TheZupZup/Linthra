import '../../core/models/cache_size.dart';
import '../../core/repositories/download_preferences.dart';

/// A non-persistent [DownloadPreferences] for development and tests.
class InMemoryDownloadPreferences implements DownloadPreferences {
  InMemoryDownloadPreferences({
    bool wifiOnly = false,
    int maxCacheBytes = CacheSize.defaultLimit,
  })  : _wifiOnly = wifiOnly,
        _maxCacheBytes = maxCacheBytes;

  bool _wifiOnly;
  int _maxCacheBytes;

  @override
  Future<bool> wifiOnly() async => _wifiOnly;

  @override
  Future<void> setWifiOnly(bool value) async {
    _wifiOnly = value;
  }

  @override
  Future<int> maxCacheBytes() async => _maxCacheBytes;

  @override
  Future<void> setMaxCacheBytes(int bytes) async {
    _maxCacheBytes = bytes;
  }
}
