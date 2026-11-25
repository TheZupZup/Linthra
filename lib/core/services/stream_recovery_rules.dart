import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../models/playback_state.dart';
import '../native/linthra_core.dart';
import '../native/linthra_core_ffi.dart';

// What the player does when a stream stalls, drops or ends: its quick
// reconnect budget, whether a source that went away ended or was lost, and
// when the buffering watchdog is armed and what its firing means.
//
// The Rust core decides when the build has it
// (native/linthra_core/src/stream_recovery.rs); the rules here are the
// fallback, and `useNative: false` keeps to them. The two are compared in
// test/core/services/stream_recovery_rules_test.dart.

/// How far one position report may move for it to be ordinary playback: a
/// seek or a reload landing moves further.
const Duration maxProgressStep = Duration(seconds: 2);

/// How close to its known end an idle source must have been heard for the
/// idle to be its end, capped at a quarter of the track.
const Duration endHeardTolerance = Duration(seconds: 2);

/// How far short of a stream's known end a reported end must come for it to
/// be a lost stream: at least this much, or a tenth of the track.
const Duration cutShortMinimum = Duration(seconds: 10);

/// The quick reconnect a dropped stream gets: one per track, given back once
/// the stream has played on for a while, so a later drop on the same track
/// reconnects quickly again.
class ReconnectBudget {
  ReconnectBudget({this.useNative = true});

  final bool useNative;

  /// Quick reconnects spent on the current track.
  int spent = 0;

  /// Playback heard since the last one.
  Duration played = Duration.zero;

  /// The position last seen while counting.
  Duration? last;

  /// Takes a quick reconnect for a failure that may clear if the stream is
  /// opened again, when one is left. Playback from here on earns it back.
  bool claim({required bool retryable, required int max}) {
    final bool taken = useNative && LinthraCore.isAvailable
        ? linthraReconnectClaim(spent, max, retryable)
        : retryable && spent < max;
    if (taken) {
      spent++;
      played = Duration.zero;
      last = null;
    }
    return taken;
  }

  /// Counts a position report towards giving the spent reconnect back.
  /// [counting] is whether the track is playing with no recovery loading:
  /// time paused, buffering or reconnecting doesn't count, nor does a seek.
  void noteProgress(
    Duration position, {
    required bool counting,
    required Duration refillAfter,
  }) {
    if (spent == 0) return;
    if (useNative && LinthraCore.isAvailable) {
      final bool gaveBack = using((Arena arena) {
        final Pointer<Int64> playedUs = arena<Int64>()
          ..value = played.inMicroseconds;
        final Pointer<Int64> lastUs = arena<Int64>()
          ..value = last?.inMicroseconds ?? _none;
        final int result = linthraReconnectProgress(spent, playedUs, lastUs,
            position.inMicroseconds, counting, refillAfter.inMicroseconds);
        played = Duration(microseconds: playedUs.value);
        last =
            lastUs.value == _none ? null : Duration(microseconds: lastUs.value);
        return result == 1;
      });
      if (gaveBack) giveBack();
      return;
    }
    if (!counting) {
      last = null;
      return;
    }
    final Duration? before = last;
    last = position;
    if (before == null) return;
    final Duration step = position - before;
    if (step <= Duration.zero || step > maxProgressStep) return;
    played += step;
    if (played < refillAfter) return;
    giveBack();
  }

  /// The stream has proven itself, or another copy took over.
  void giveBack() {
    spent = 0;
    played = Duration.zero;
    last = null;
  }

  // The smallest Int64: no position.
  static const int _none = -0x8000000000000000;
}

/// How the engine said a source is gone.
enum SourceGone {
  /// An idle no load or stop of ours explains, on an engine that reports a
  /// lost source only that way (libmpv on Linux).
  idle,

  /// The engine reported the end of the source.
  completed,
}

/// Whether a source that went away ended (it was heard) or was lost (it is
/// recovered like a dropped stream, without counting as played).
enum SourceEnd { ended, lost }

/// Whether a source that went away ended or was lost.
///
/// An idle on an engine that reports a lost source that way is an end only
/// when the track was heard (playing or buffering) to within
/// [endHeardTolerance] of its known end, or a quarter of it for a short one.
///
/// A completion is an end, except a stream's on such an engine that comes
/// well short of its known end (#905): libmpv gives up on a server that
/// stopped answering by reporting the end of the file, which would otherwise
/// move the queue on and record the track as played. Short means more than
/// [cutShortMinimum] or a tenth of the track before the end, whichever is
/// longer, so an estimated VBR length still ends where it ends.
SourceEnd sourceEnd(
  SourceGone gone, {
  required bool engineReportsFailureAsIdle,
  required bool stream,
  required PlaybackStatus status,
  required Duration position,
  required Duration duration,
  bool useNative = true,
}) {
  if (useNative && LinthraCore.isAvailable) {
    final int native = linthraSourceEnd(gone.index, engineReportsFailureAsIdle,
        stream, status.index, position.inMicroseconds, duration.inMicroseconds);
    if (native < SourceEnd.values.length) return SourceEnd.values[native];
  }
  final Duration remaining = duration - position;
  switch (gone) {
    case SourceGone.idle:
      final bool heard = status == PlaybackStatus.playing ||
          status == PlaybackStatus.buffering;
      final Duration quarter = duration ~/ 4;
      final Duration tolerance =
          quarter < endHeardTolerance ? quarter : endHeardTolerance;
      return heard && duration > Duration.zero && remaining <= tolerance
          ? SourceEnd.ended
          : SourceEnd.lost;
    case SourceGone.completed:
      final Duration tenth = duration ~/ 10;
      final Duration margin = tenth > cutShortMinimum ? tenth : cutShortMinimum;
      final bool cutShort = engineReportsFailureAsIdle &&
          stream &&
          duration > Duration.zero &&
          position >= Duration.zero &&
          remaining > margin;
      return cutShort ? SourceEnd.lost : SourceEnd.ended;
  }
}

/// Whether an engine report of buffering arms the watchdog: a stall on a
/// track that was playing, or resuming into one on a track that has played
/// (a first load is not a stall).
bool watchdogArms(
  PlaybackStatus reported,
  PlaybackStatus current, {
  required bool hasPlayed,
  bool useNative = true,
}) {
  if (useNative && LinthraCore.isAvailable) {
    final int native =
        linthraWatchdogArms(reported.index, current.index, hasPlayed);
    if (native <= 1) return native == 1;
  }
  return reported == PlaybackStatus.buffering &&
      (current == PlaybackStatus.playing ||
          (hasPlayed && current != PlaybackStatus.buffering));
}

/// Whether the watchdog firing is a failure: still stalled or reconnecting,
/// with a track to recover and no automatic recovery already under way.
bool watchdogFails(
  PlaybackStatus current, {
  required bool recoveryUnderway,
  required bool hasTrack,
  bool useNative = true,
}) {
  if (useNative && LinthraCore.isAvailable) {
    final int native =
        linthraWatchdogFails(current.index, recoveryUnderway, hasTrack);
    if (native <= 1) return native == 1;
  }
  return !recoveryUnderway &&
      hasTrack &&
      (current == PlaybackStatus.buffering ||
          current == PlaybackStatus.reconnecting);
}
