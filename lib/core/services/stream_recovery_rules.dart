import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../models/playback_state.dart';
import '../native/linthra_core_ffi.dart';

// What the player does when a stream stalls, drops or ends: its quick
// reconnect budget, whether a source that went away ended or was lost, and
// when the buffering watchdog is armed and what its firing means.
//
// Decided by the Rust core (native/linthra_core/src/stream_recovery.rs);
// these are the calls into it, with the state it works on.

/// The quick reconnect a dropped stream gets: one per track, given back once
/// the stream has played on for a while, so a later drop on the same track
/// reconnects quickly again.
class ReconnectBudget {
  /// Quick reconnects spent on the current track.
  int spent = 0;

  /// Playback heard since the last one.
  Duration played = Duration.zero;

  /// The position last seen while counting.
  Duration? last;

  /// Takes a quick reconnect for a failure that may clear if the stream is
  /// opened again, when one is left. Playback from here on earns it back.
  bool claim({required bool retryable, required int max}) {
    final bool taken = linthraReconnectClaim(spent, max, retryable);
    if (taken) {
      spent++;
      played = Duration.zero;
      last = null;
    }
    return taken;
  }

  /// Counts a position report towards giving the spent reconnect back.
  /// [counting] is whether the track is playing with no recovery loading:
  /// time paused, buffering or reconnecting doesn't count, nor does a seek
  /// (a report that moves more than two seconds).
  void noteProgress(
    Duration position, {
    required bool counting,
    required Duration refillAfter,
  }) {
    if (spent == 0) return;
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
/// two seconds of its known end, or a quarter of it for a short one.
///
/// A completion is an end, except a stream's on such an engine that comes
/// well short of its known end (#905): libmpv gives up on a server that
/// stopped answering by reporting the end of the file, which would otherwise
/// move the queue on and record the track as played. Short means more than
/// ten seconds or a tenth of the track before the end, whichever is
/// longer, so an estimated VBR length still ends where it ends.
SourceEnd sourceEnd(
  SourceGone gone, {
  required bool engineReportsFailureAsIdle,
  required bool stream,
  required PlaybackStatus status,
  required Duration position,
  required Duration duration,
}) {
  final int native = linthraSourceEnd(gone.index, engineReportsFailureAsIdle,
      stream, status.index, position.inMicroseconds, duration.inMicroseconds);
  return SourceEnd.values[_known(native, SourceEnd.values.length)];
}

/// Whether an engine report of buffering arms the watchdog: a stall on a
/// track that was playing, or resuming into one on a track that has played
/// (a first load is not a stall).
bool watchdogArms(
  PlaybackStatus reported,
  PlaybackStatus current, {
  required bool hasPlayed,
}) =>
    _known(linthraWatchdogArms(reported.index, current.index, hasPlayed), 2) ==
    1;

/// Whether the watchdog firing is a failure: still stalled or reconnecting,
/// with a track to recover and no automatic recovery already under way.
bool watchdogFails(
  PlaybackStatus current, {
  required bool recoveryUnderway,
  required bool hasTrack,
}) =>
    _known(
        linthraWatchdogFails(current.index, recoveryUnderway, hasTrack), 2) ==
    1;

/// [answer], one of [count] codes; every input comes from a Dart enum, so
/// another means the two sides of the ABI disagree.
int _known(int answer, int count) {
  if (answer < 0 || answer >= count) {
    throw StateError('the Rust stream recovery rules answered $answer');
  }
  return answer;
}
