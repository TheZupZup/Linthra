import 'linthra_core.dart';
import 'linthra_core_ffi.dart';

/// The end-of-track rule in the Rust core (native/linthra_core/src/track_end.rs).
///
/// Use `trackEndAction`, which calls this and falls back to its Dart rule
/// without the Rust core.
abstract final class NativeTrackEnd {
  /// The `TrackEndAction.index` for a repeat mode's index, or null when there
  /// is no Rust core or it did not know the code.
  static int? action(int repeatIndex, {required bool hasNext}) {
    if (!LinthraCore.isAvailable) return null;
    final int code = linthraTrackEndAction(repeatIndex, hasNext);
    return code < 4 ? code : null;
  }
}
