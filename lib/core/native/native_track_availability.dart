import 'linthra_core.dart';
import 'linthra_core_ffi.dart';

/// The library row's availability rule in the Rust core
/// (native/linthra_core/src/track_availability.rs).
///
/// Use `resolveTrackAvailability`, which calls this and falls back to its
/// Dart rule without the Rust core.
abstract final class NativeTrackAvailability {
  /// The `TrackAvailabilityStatus.index` for a `SourceAvailability.index`, or
  /// null when there is no Rust core or it did not know the code.
  static int? resolve({
    required bool isRemote,
    required bool hasOfflineCopy,
    required bool isExplicitDownload,
    required int availabilityIndex,
  }) {
    if (!LinthraCore.isAvailable) return null;
    final int code = linthraTrackAvailability(
      isRemote,
      hasOfflineCopy,
      isExplicitDownload,
      availabilityIndex,
    );
    return code < 7 ? code : null;
  }
}
