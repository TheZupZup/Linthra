import 'dart:async';

import 'package:linthra/core/lifecycle/system_sleep_watcher.dart';

/// The machine's clocks as a [SystemSleepWatcher] sees them, moved by hand.
///
/// [sleep] is a real suspend: the boot clock runs ahead of the monotonic one.
/// Time passing while awake (a window hidden for an hour, a clock set back)
/// moves both together, which is why it has no method here: the watcher
/// cannot see it. [look] is the watcher's next periodic look, the first of
/// which comes some seconds after the wake.
class FakeMachineSleep {
  Duration _asleep = Duration.zero;
  _ManualTimer? _timer;

  /// Set to make the next readings fail, as an unreadable `/proc` would.
  bool unreadable = false;

  /// A watcher on these clocks. One per test: it is the player's to dispose.
  SystemSleepWatcher watcher() => SystemSleepWatcher(
        timeAsleep: () => unreadable ? null : _asleep,
        createPeriodic: (Duration interval, void Function(Timer) look) =>
            _timer = _ManualTimer(look),
      );

  /// Whether the watcher is looking right now.
  bool get isWatched => _timer?.isActive ?? false;

  /// Suspends the machine for [duration] and wakes it.
  void sleep(Duration duration) => _asleep += duration;

  /// The watcher's next look, if it is looking.
  void look() => _timer?.fire();
}

class _ManualTimer implements Timer {
  _ManualTimer(this._look);

  final void Function(Timer) _look;
  bool _active = true;
  int _ticks = 0;

  void fire() {
    if (!_active) return;
    _ticks++;
    _look(this);
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => _ticks;
}
