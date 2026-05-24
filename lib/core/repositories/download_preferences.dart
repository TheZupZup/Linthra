import '../models/cache_size.dart';

/// The user's download/offline preferences.
///
/// These are kept behind an interface so the [DownloadRepository] and cache
/// manager can consult them without binding to a storage plugin. The policy
/// lives in the repository; this only remembers the choices:
///  - "Wi-Fi only": downloads that would run over mobile data are queued.
///  - "Max cache size": the byte ceiling the offline cache is kept under, with
///    least-recently-used eviction once a new download would exceed it.
abstract interface class DownloadPreferences {
  /// Whether downloads should only run on Wi-Fi. Defaults to `false`.
  Future<bool> wifiOnly();

  Future<void> setWifiOnly(bool value);

  /// The maximum total size of the offline cache in bytes. Defaults to
  /// [CacheSize.defaultLimit] when the user hasn't chosen one.
  Future<int> maxCacheBytes();

  Future<void> setMaxCacheBytes(int bytes);
}
