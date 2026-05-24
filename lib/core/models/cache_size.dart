/// Cache-size presets, the default limit, and byte formatting — the small,
/// pure pieces the cache settings UI and persistence share.
///
/// Sizes are in bytes throughout the cache layer so there is one unit; the
/// presets and [formatBytes] are the only place the GB/MB labels live.
abstract final class CacheSize {
  const CacheSize._();

  static const int bytesPerKb = 1024;
  static const int bytesPerMb = 1024 * bytesPerKb;
  static const int bytesPerGb = 1024 * bytesPerMb;

  /// Convert a whole-GB value to bytes.
  static int gigabytes(num gb) => (gb * bytesPerGb).round();

  /// The preset limits offered in Settings, in bytes: 1, 2, 4, 8, 16 GB.
  static const List<int> presets = <int>[
    1 * bytesPerGb,
    2 * bytesPerGb,
    4 * bytesPerGb,
    8 * bytesPerGb,
    16 * bytesPerGb,
  ];

  /// A sane default that won't fill a phone unexpectedly while still holding a
  /// good amount of offline music.
  static const int defaultLimit = 4 * bytesPerGb;

  /// Guard rails for a custom value so the field can't be set to something
  /// nonsensical (0, negative, or larger than any phone).
  static const int minLimit = 256 * bytesPerMb;
  static const int maxLimit = 512 * bytesPerGb;

  /// Clamp [bytes] into the supported range.
  static int clamp(int bytes) {
    if (bytes < minLimit) return minLimit;
    if (bytes > maxLimit) return maxLimit;
    return bytes;
  }

  /// Whether [bytes] is one of the named [presets] (so the picker can mark it
  /// selected rather than treating it as a custom value).
  static bool isPreset(int bytes) => presets.contains(bytes);

  /// A short, human-friendly size label (e.g. `4 GB`, `1.5 GB`, `512 MB`,
  /// `0 B`). Whole numbers drop the decimal; otherwise one decimal place.
  static String formatBytes(int bytes) {
    if (bytes < bytesPerKb) return '$bytes B';
    final double value;
    final String unit;
    if (bytes >= bytesPerGb) {
      value = bytes / bytesPerGb;
      unit = 'GB';
    } else if (bytes >= bytesPerMb) {
      value = bytes / bytesPerMb;
      unit = 'MB';
    } else {
      value = bytes / bytesPerKb;
      unit = 'KB';
    }
    final String text = value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    return '$text $unit';
  }
}
