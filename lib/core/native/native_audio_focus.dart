import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'linthra_core_ffi.dart';

/// The player's audio focus machine in the Rust core
/// (native/linthra_core/src/audio_focus.rs). Use `AudioFocusMachine`, which
/// calls this.
abstract final class NativeAudioFocus {
  static const int _capacity = 32;

  /// The next state's bits and the steps for one event.
  static (int, List<int>) step(int state, int event, int context) {
    return using((Arena arena) {
      final Pointer<Uint8> steps = arena<Uint8>(_capacity);
      final Pointer<Size> count = arena<Size>();
      final int next =
          linthraAudioFocusStep(state, event, context, steps, _capacity, count);
      // Every event comes from a Dart enum, so one Rust doesn't know means
      // the two sides of the ABI disagree.
      if (next == 0xFFFF) {
        throw StateError('linthra_audio_focus_step refused event $event');
      }
      return (next, List<int>.of(steps.asTypedList(count.value)));
    });
  }
}
