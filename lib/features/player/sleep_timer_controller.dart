import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'player_providers.dart';

/// Immutable snapshot of the sleep timer, rendered by the sleep-timer sheet and
/// the Now Playing action button.
///
/// Inactive by default. When [isActive] both [total] (the chosen delay) and
/// [remaining] (the live countdown) are non-null; the controller emits a fresh
/// state once a second so the UI shows a ticking countdown without owning a
/// timer of its own.
@immutable
class SleepTimerState {
  const SleepTimerState({this.total, this.remaining});

  /// No timer running.
  static const SleepTimerState inactive = SleepTimerState();

  /// The chosen delay, or null when no timer is running.
  final Duration? total;

  /// How long until playback pauses, or null when no timer is running.
  final Duration? remaining;

  /// Whether a countdown is currently running.
  bool get isActive => total != null && remaining != null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SleepTimerState &&
          other.total == total &&
          other.remaining == remaining);

  @override
  int get hashCode => Object.hash(total, remaining);
}

/// Owns the Sleep Timer: a single countdown that pauses playback when it
/// reaches zero, so the listener can fall asleep to music and have it stop on
/// its own.
///
/// It drives playback only through the unified [PlaybackController] — pausing
/// (never stopping) on expiry, so the queue and position survive and playback
/// can be resumed where it left off. It never touches a music source, the
/// offline cache, casting, or the sync logic. The countdown is exposed as plain
/// [SleepTimerState] the UI renders from; the ticking [Timer] is an internal
/// detail, injectable so tests can drive expiry deterministically without real
/// time passing.
class SleepTimerController extends Notifier<SleepTimerState> {
  SleepTimerController({
    Timer Function(Duration, void Function(Timer))? createPeriodic,
    Duration tick = const Duration(seconds: 1),
    DateTime Function()? now,
  })  : _createPeriodic = createPeriodic ?? Timer.periodic,
        _tick = tick,
        _now = now ?? DateTime.now;

  final Timer Function(Duration, void Function(Timer)) _createPeriodic;
  final Duration _tick;
  final DateTime Function() _now;
  Timer? _timer;

  /// When the countdown runs out, on the wall clock.
  ///
  /// The ticks alone are not enough. Dart's timers run on the monotonic clock,
  /// which stands still while the machine is suspended (a Linux laptop asleep,
  /// an Android phone in deep sleep), so after the wake the periodic timer just
  /// delivers the tick after the last one, as if no time had passed. A
  /// countdown that should have run out during the night would then let the
  /// music that carries on after the wake play for whatever it still showed.
  DateTime? _deadline;

  @override
  SleepTimerState build() {
    // The countdown must never outlive the provider scope, so always release
    // the timer on dispose.
    ref.onDispose(_clearTimer);
    return SleepTimerState.inactive;
  }

  /// Starts (or replaces) the countdown for [duration], after which playback
  /// pauses. A non-positive [duration] is ignored.
  void start(Duration duration) {
    if (duration <= Duration.zero) return;
    _clearTimer();
    _deadline = _deadlineAfter(duration);
    state = SleepTimerState(total: duration, remaining: duration);
    _timer = _createPeriodic(_tick, _onTick);
  }

  /// Cancels the active countdown, leaving playback untouched. A no-op when no
  /// timer is running.
  void cancel() {
    if (!state.isActive) return;
    _clearTimer();
    state = SleepTimerState.inactive;
  }

  void _onTick(Timer timer) {
    // Defensive: a stray tick after the timer was cleared must change nothing.
    if (!state.isActive) return;
    Duration remaining = state.remaining! - _tick;
    // Time the machine spent asleep counts too: never further from the end
    // than the wall clock says. Only ever brought forward, so a clock set
    // back cannot stretch the countdown.
    final DateTime? deadline = _deadline;
    if (deadline != null) {
      final Duration byClock = deadline.difference(_now());
      if (byClock < remaining) remaining = byClock;
    }
    if (remaining <= Duration.zero) {
      // Reached zero: stop ticking and clear the state first, then pause
      // playback through the unified controller. Pause (not stop) so resuming
      // later picks up the same track, queue, and position.
      _clearTimer();
      state = SleepTimerState.inactive;
      unawaited(ref.read(playbackControllerProvider).pause());
      return;
    }
    state = SleepTimerState(total: state.total, remaining: remaining);
  }

  /// [duration] from now on the wall clock, or null when that lies past what a
  /// [DateTime] can hold (a custom delay of billions of minutes): the ticks
  /// alone count that one down.
  DateTime? _deadlineAfter(Duration duration) {
    try {
      return _now().add(duration);
    } on ArgumentError {
      return null;
    }
  }

  void _clearTimer() {
    _timer?.cancel();
    _timer = null;
    _deadline = null;
  }
}

final sleepTimerControllerProvider =
    NotifierProvider<SleepTimerController, SleepTimerState>(
  SleepTimerController.new,
);
