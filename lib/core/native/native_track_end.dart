import 'linthra_core_ffi.dart';

/// The end-of-track rule in the Rust core (native/linthra_core/src/track_end.rs).
///
/// Use `trackEndAction`, which calls this.
abstract final class NativeTrackEnd {
  /// The `TrackEndAction.index` for a repeat mode's index.
  static int action(int repeatIndex, {required bool hasNext}) {
    final int code = linthraTrackEndAction(repeatIndex, hasNext);
    // Every index comes from a Dart enum, so a code Rust doesn't know means
    // the two sides of the ABI disagree.
    if (code >= 4) {
      throw StateError('linthra_track_end_action refused $repeatIndex');
    }
    return code;
  }
}
