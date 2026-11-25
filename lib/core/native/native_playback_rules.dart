import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'linthra_core.dart';
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
/// Every call answers with codes numbered like the Dart enums, or null when
/// the build has no Rust core (or Rust didn't know the code), so each caller
/// falls back to its own Dart rule.
abstract final class NativePlaybackRules {
  static const int _invalid = 255;

  /// The `StreamInterruptionKind` index [text] reads as.
  static int? classifyError(String text) {
    if (!LinthraCore.isAvailable) return null;
    final Uint8List bytes = utf8.encode(text);
    final int kind = using((Arena arena) {
      final Pointer<Uint8> native = arena<Uint8>(bytes.length + 1);
      native.asTypedList(bytes.length).setAll(0, bytes);
      return linthraPlaybackClassifyError(native, bytes.length);
    });
    return kind == _invalid ? null : kind;
  }

  /// The (`PlaybackFailureKind`, `PlaybackFailureCause`) indices for a
  /// `PlaybackResolutionErrorKind` index.
  static (int, int)? failureForResolution(int kind) => LinthraCore.isAvailable
      ? _split(linthraPlaybackFailureForResolution(kind))
      : null;

  /// The (`PlaybackFailureKind`, `PlaybackFailureCause`) indices for a
  /// `StreamInterruptionKind` index.
  static (int, int)? failureForInterruption(int kind) => LinthraCore.isAvailable
      ? _split(linthraPlaybackFailureForInterruption(kind))
      : null;

  static (int, int)? _split(int packed) =>
      packed == 0xFFFF ? null : (packed >> 8, packed & 0xFF);

  /// The `PlaybackRecoveryStep` index and its wait, for a failure of the
  /// `PlaybackFailureKind` index [kind].
  static (int, Duration)? recoveryDecision({
    required int kind,
    required int failuresBefore,
    required bool retrySpent,
    required NativeNextTrack next,
    required Duration retryDelay,
    required Duration advanceDelay,
    required Duration maxAdvanceDelay,
    required int maxConsecutiveFailures,
  }) {
    if (!LinthraCore.isAvailable) return null;
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
      return step == _invalid
          ? null
          : (step, Duration(milliseconds: delay.value));
    });
  }

  /// The `AudioFocusAction` index for an interruption beginning (or ending)
  /// with the `AudioInterruptionType` index [interruption].
  static int? focusAction({required bool begin, required int interruption}) {
    if (!LinthraCore.isAvailable) return null;
    final int action = linthraPlaybackFocusAction(begin, interruption);
    return action == _invalid ? null : action;
  }
}
