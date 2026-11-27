import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'linthra_core_ffi.dart';

/// Where the queue would move after a failed track, as the Rust recovery
/// policy is told (native/linthra_core/src/playback_rules.rs).
enum NativeNextTrack {
  /// The queue ends here.
  none,

  /// Back to the failed track itself.
  same,

  /// To a track that already failed in this streak.
  failedBefore,

  /// To a track that hasn't failed yet.
  fresh,
}

/// The player's rules in the Rust core: what an engine error means, the
/// failure it records, what to do next, and what a focus change asks for.
///
/// Every call answers with codes numbered like the Dart enums. Every code
/// sent comes from a Dart enum too, so one Rust doesn't know means the two
/// sides of the ABI disagree, and throws.
abstract final class NativePlaybackRules {
  static const int _invalid = 255;

  /// The `StreamInterruptionKind` index [text] reads as.
  static int classifyError(String text) {
    final Uint8List bytes = utf8.encode(text);
    final int kind = using((Arena arena) {
      final Pointer<Uint8> native = arena<Uint8>(bytes.length + 1);
      native.asTypedList(bytes.length).setAll(0, bytes);
      return linthraPlaybackClassifyError(native, bytes.length);
    });
    return _known(kind, 'linthra_playback_classify_error');
  }

  /// The (`PlaybackFailureKind`, `PlaybackFailureCause`) indices for a
  /// `PlaybackResolutionErrorKind` index.
  static (int, int) failureForResolution(int kind) =>
      _split(linthraPlaybackFailureForResolution(kind), kind);

  /// The (`PlaybackFailureKind`, `PlaybackFailureCause`) indices for a
  /// `StreamInterruptionKind` index.
  static (int, int) failureForInterruption(int kind) =>
      _split(linthraPlaybackFailureForInterruption(kind), kind);

  static (int, int) _split(int packed, int kind) {
    if (packed == 0xFFFF) {
      throw StateError('the Rust playback rules refused kind $kind');
    }
    return (packed >> 8, packed & 0xFF);
  }

  static int _known(int answer, String call) {
    if (answer == _invalid) throw StateError('$call refused its input');
    return answer;
  }

  /// The `PlaybackRecoveryStep` index and its wait, for a failure of the
  /// `PlaybackFailureKind` index [kind].
  static (int, Duration) recoveryDecision({
    required int kind,
    required int failuresBefore,
    required bool retrySpent,
    required NativeNextTrack next,
    required Duration retryDelay,
    required Duration advanceDelay,
    required Duration maxAdvanceDelay,
    required int maxConsecutiveFailures,
  }) {
    return using((Arena arena) {
      final Pointer<Uint64> delay = arena<Uint64>();
      final int step = linthraPlaybackRecoveryDecide(
        kind,
        failuresBefore,
        retrySpent,
        next.index,
        retryDelay.inMilliseconds,
        advanceDelay.inMilliseconds,
        maxAdvanceDelay.inMilliseconds,
        maxConsecutiveFailures,
        delay,
      );
      return (
        _known(step, 'linthra_playback_recovery_decide'),
        Duration(milliseconds: delay.value),
      );
    });
  }

  /// The `AudioFocusAction` index for an interruption beginning (or ending)
  /// with the `AudioInterruptionType` index [interruption].
  static int focusAction({required bool begin, required int interruption}) =>
      _known(
        linthraPlaybackFocusAction(begin, interruption),
        'linthra_playback_focus_action',
      );
}
