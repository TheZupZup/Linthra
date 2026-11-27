import 'linthra_core_ffi.dart';

/// The library row's availability rule in the Rust core
/// (native/linthra_core/src/track_availability.rs).
///
/// Use `resolveTrackAvailability`, which calls this.
abstract final class NativeTrackAvailability {
  /// The `TrackAvailabilityStatus.index` for a `SourceAvailability.index`.
  static int resolve({
    required bool isRemote,
    required bool hasOfflineCopy,
    required bool isExplicitDownload,
    required int availabilityIndex,
  }) {
    final int code = linthraTrackAvailability(
      isRemote,
      hasOfflineCopy,
      isExplicitDownload,
      availabilityIndex,
    );
    // Every index comes from a Dart enum, so a code Rust doesn't know means
    // the two sides of the ABI disagree.
    if (code >= 7) {
      throw StateError('linthra_track_availability refused $availabilityIndex');
    }
    return code;
  }
}
