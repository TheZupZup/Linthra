import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'linthra_core.dart';
import 'linthra_core_ffi.dart';

/// The player's audio focus machine in the Rust core
/// (native/linthra_core/src/audio_focus.rs). Use `AudioFocusMachine`, which
/// calls this and runs its Dart rules without the Rust core.
abstract final class NativeAudioFocus {
  static const int _capacity = 32;

  /// The next state's bits and the steps for one event, or null when there
  /// is no Rust core or it didn't know the event.
  static (int, List<int>)? step(int state, int event, int context) {
    if (!LinthraCore.isAvailable) return null;
    return using((Arena arena) {
      final Pointer<Uint8> steps = arena<Uint8>(_capacity);
      final Pointer<Size> count = arena<Size>();
      final int next =
          linthraAudioFocusStep(state, event, context, steps, _capacity, count);
      if (next == 0xFFFF) return null;
      return (next, List<int>.of(steps.asTypedList(count.value)));
    });
  }
}
