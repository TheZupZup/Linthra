import '../models/cache_size.dart';

/// The named number-of-upcoming-tracks presets offered for smart pre-cache,
/// shown in Settings (smallest first). The small values keep playback seamless
/// without hoarding the cache; the larger ones let users warm a longer run of
/// the queue. Anything in between — up to [kMaxPrecacheCount] — is reachable as
/// a custom value, so this list is just the convenient one-tap choices.
const List<int> kPrecacheCountOptions = <int>[1, 3, 5, 10, 20, 50];

/// How many upcoming tracks smart pre-cache warms when the user hasn't chosen.
/// Modest by design — a few tracks ahead, never the whole queue. Kept at 3 so
/// upgrading users see no change in behaviour.
const int kDefaultPrecacheCount = 3;

/// Safe bounds for the pre-cache count (inclusive). The minimum keeps the
/// feature meaningful (at least the next track); the maximum stops a custom
/// value from queuing a flood of downloads — pre-cache warms the next few
/// songs, never the whole library.
const int kMinPrecacheCount = 1;
const int kMaxPrecacheCount = 200;

/// Clamps an arbitrary pre-cache count into the supported range so a corrupt,
/// out-of-range, or hand-typed value can never disable pre-cache or queue
/// thousands of downloads. A value below [kMinPrecacheCount] is treated as junk
/// and restored to [kDefaultPrecacheCount]; a value above [kMaxPrecacheCount] is
/// capped at the maximum; any value already in range — a [kPrecacheCountOptions]
/// preset or a custom number — is kept as-is.
int sanitizePrecacheCount(int value) {
  if (value < kMinPrecacheCount) return kDefaultPrecacheCount;
  if (value > kMaxPrecacheCount) return kMaxPrecacheCount;
  return value;
}

/// Whether [count] is one of the named [kPrecacheCountOptions], so the picker
/// can show it as a selected preset rather than a custom value.
bool isPrecacheCountPreset(int count) => kPrecacheCountOptions.contains(count);

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
  /// A [kPrecacheCountOptions] preset or any custom value within
  /// [kMinPrecacheCount]–[kMaxPrecacheCount]; defaults to
  /// [kDefaultPrecacheCount].
  Future<int> precacheCount();

  Future<void> setPrecacheCount(int value);
}
