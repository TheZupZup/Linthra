import '../models/cache_size.dart';

/// The number-of-upcoming-tracks choices offered for smart pre-cache, shown in
/// Settings. Small on purpose: enough for seamless playback without hoarding
/// the cache or risking a "download the whole library" feel.
const List<int> kPrecacheCountOptions = <int>[1, 3, 5, 10];

/// How many upcoming tracks smart pre-cache warms when the user hasn't chosen.
/// Modest by design — a few tracks ahead, never the whole queue.
const int kDefaultPrecacheCount = 3;

/// Clamps an arbitrary value to one of [kPrecacheCountOptions], so a corrupt or
/// out-of-range stored value can never widen pre-caching beyond the offered
/// choices. Returns [kDefaultPrecacheCount] when [value] isn't an offered count.
int sanitizePrecacheCount(int value) =>
    kPrecacheCountOptions.contains(value) ? value : kDefaultPrecacheCount;

/// The user's download/offline preferences.
///
/// These are kept behind an interface so the [DownloadRepository] and cache
/// manager can consult them without binding to a storage plugin. The policy
/// lives in the repository; this only remembers the choices:
///  - "Allow mobile data": when off (the safe default), downloads and smart
///    pre-cache run only on Wi-Fi and are queued on mobile data; when on, they
///    may also run over a metered/cellular connection.
///  - "Max cache size": the byte ceiling the offline cache is kept under, with
///    least-recently-used eviction once a new download would exceed it.
///  - Smart pre-cache "on/off" and "how many upcoming tracks": whether, and how
///    far ahead, playback warms the next queued tracks into the cache.
abstract interface class DownloadPreferences {
  /// Whether downloads and smart pre-cache may use mobile data. Defaults to
  /// `false`, so the safe behaviour out of the box is Wi-Fi only.
  Future<bool> allowMobileData();

  Future<void> setAllowMobileData(bool value);

  /// The maximum total size of the offline cache in bytes. Defaults to
  /// [CacheSize.defaultLimit] when the user hasn't chosen one.
  Future<int> maxCacheBytes();

  Future<void> setMaxCacheBytes(int bytes);

  /// Whether smart pre-cache is on: upcoming queued tracks are warmed into the
  /// cache ahead of play. Defaults to `true`. Pre-cached bytes are bounded by
  /// [maxCacheBytes], skipped (not queued) when the connection isn't allowed by
  /// the mobile-data policy, and evicted before any user download.
  Future<bool> preloadEnabled();

  Future<void> setPreloadEnabled(bool value);

  /// How many upcoming tracks smart pre-cache warms ahead of the current one.
  /// One of [kPrecacheCountOptions]; defaults to [kDefaultPrecacheCount].
  Future<int> precacheCount();

  Future<void> setPrecacheCount(int value);
}
