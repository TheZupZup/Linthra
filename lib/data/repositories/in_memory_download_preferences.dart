import '../../core/models/cache_size.dart';
import '../../core/repositories/download_preferences.dart';

/// A non-persistent [DownloadPreferences] for development and tests.
class InMemoryDownloadPreferences implements DownloadPreferences {
  InMemoryDownloadPreferences({
    bool allowMobileData = false,
    int maxCacheBytes = CacheSize.defaultLimit,
    bool preloadEnabled = true,
    int precacheCount = kDefaultPrecacheCount,
  })  : _allowMobileData = allowMobileData,
        _maxCacheBytes = maxCacheBytes,
        _preloadEnabled = preloadEnabled,
        _precacheCount = sanitizePrecacheCount(precacheCount);

  bool _allowMobileData;
  int _maxCacheBytes;
  bool _preloadEnabled;
  int _precacheCount;

  @override
  Future<bool> allowMobileData() async => _allowMobileData;

  @override
  Future<void> setAllowMobileData(bool value) async {
    _allowMobileData = value;
  }

  @override
  Future<int> maxCacheBytes() async => _maxCacheBytes;

  @override
  Future<void> setMaxCacheBytes(int bytes) async {
    _maxCacheBytes = bytes;
  }

  @override
  Future<bool> preloadEnabled() async => _preloadEnabled;

  @override
  Future<void> setPreloadEnabled(bool value) async {
    _preloadEnabled = value;
  }

  @override
  Future<int> precacheCount() async => _precacheCount;

  @override
  Future<void> setPrecacheCount(int value) async {
    _precacheCount = sanitizePrecacheCount(value);
  }
}
