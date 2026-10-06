import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Reads how long the machine has spent asleep since some fixed point, or null
/// when that can't be read right now.
typedef TimeAsleepReader = Duration? Function();

/// Notices that the machine slept, so the player can reload what was playing
/// once it wakes (#466, #799).
///
/// Linux tells a running app nothing about a system suspend. Flutter's Linux
/// embedder reports the window's focus and visibility (`resumed`, `inactive`,
/// `hidden`), never `paused`, and a suspend changes neither: at most the lock
/// screen takes focus on the way down. A minimized or hidden window reports
/// `hidden` while nothing sleeps at all.
///
/// The kernel keeps count, though. Its boot clock (`CLOCK_BOOTTIME`, which
/// `/proc/uptime` reads) goes on counting while the machine is suspended, and
/// the monotonic clock behind [Stopwatch] stands still, so the first runs
/// ahead of the second by exactly the time spent asleep. Neither can be set:
/// a clock change, an NTP correction or a window hidden for hours moves both
/// the same way and never reads as a sleep. Reading them needs no permission,
/// in the Flatpak or out of it.
///
/// It only looks while asked to ([watch]). The player asks while it is
/// playing, the one time a sleep needs recovering from, so an idle or paused
/// Linthra holds no timer for it, and a sleep taken while it wasn't looking is
/// never reported.
class SystemSleepWatcher {
  SystemSleepWatcher({
    required TimeAsleepReader timeAsleep,
    this.interval = const Duration(seconds: 2),
    this.threshold = const Duration(seconds: 1),
    Timer Function(Duration, void Function(Timer))? createPeriodic,
  })  : _timeAsleep = timeAsleep,
        _createPeriodic = createPeriodic ?? Timer.periodic;

  /// The watcher for this Linux machine, or null when its boot clock can't be
  /// read: the player then goes without the reload after a sleep.
  static SystemSleepWatcher? linux() {
    final TimeAsleepReader? timeAsleep = linuxTimeAsleep();
    if (timeAsleep == null) return null;
    return SystemSleepWatcher(timeAsleep: timeAsleep);
  }

  /// How long after the wake a sleep is noticed, at most.
  final Duration interval;

  /// The least time asleep that counts as a sleep: far above what the two
  /// clocks can disagree by when read one after the other (`/proc/uptime`
  /// counts in hundredths of a second), and far below any real suspend.
  final Duration threshold;

  final TimeAsleepReader _timeAsleep;
  final Timer Function(Duration, void Function(Timer)) _createPeriodic;
  final StreamController<Duration> _wakes =
      StreamController<Duration>.broadcast();

  Timer? _timer;
  Duration? _last;
  bool _disposed = false;

  /// Each sleep noticed while watching, as the time spent asleep.
  Stream<Duration> get wakes => _wakes.stream;

  /// Whether it is looking right now.
  bool get isWatching => _timer != null;

  /// Time spent asleep so far, or null when it can't be read now. Kept by the
  /// player against what it loads, for [sleptSince].
  Duration? timeAsleep() => _timeAsleep();

  /// Whether the machine has slept since [reading], an earlier [timeAsleep].
  /// False when either reading is missing: an unknown is not a sleep.
  bool sleptSince(Duration? reading) {
    if (reading == null) return false;
    final Duration? now = _timeAsleep();
    return now != null && now - reading >= threshold;
  }

  /// Starts or stops looking. Looking starts from a fresh reading, so a sleep
  /// taken while it wasn't looking is never reported.
  void watch(bool enabled) {
    if (_disposed || enabled == isWatching) return;
    if (!enabled) {
      _timer!.cancel();
      _timer = null;
      return;
    }
    _last = _timeAsleep();
    _timer = _createPeriodic(interval, (_) => _check());
  }

  void _check() {
    final Duration? now = _timeAsleep();
    // A reading that failed changes nothing: the next good one is compared
    // with the last good one, so a sleep around a failed read still counts.
    if (now == null) return;
    final Duration? last = _last;
    _last = now;
    if (last == null || _wakes.isClosed) return;
    final Duration slept = now - last;
    if (slept >= threshold) _wakes.add(slept);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    await _wakes.close();
  }

  /// Time asleep on Linux: how far the boot clock has run ahead of the
  /// monotonic one since this was called. Null when the boot clock can't be
  /// read at all (no `/proc` to read it from).
  @visibleForTesting
  static TimeAsleepReader? linuxTimeAsleep({
    String Function()? readUptime,
    Duration Function()? monotonic,
  }) {
    final String Function() read = readUptime ?? _readProcUptime;
    Duration? boot() {
      try {
        return parseUptime(read());
      } on Exception {
        return null;
      }
    }

    final Duration? bootAtStart = boot();
    if (bootAtStart == null) return null;
    final Stopwatch stopwatch = Stopwatch()..start();
    final Duration Function() awake = monotonic ?? () => stopwatch.elapsed;
    final Duration awakeAtStart = awake();
    return () {
      final Duration? now = boot();
      if (now == null) return null;
      return (now - bootAtStart) - (awake() - awakeAtStart);
    };
  }

  static String _readProcUptime() => File('/proc/uptime').readAsStringSync();

  static final RegExp _uptimeLine = RegExp(r'^(\d{1,12})\.(\d{1,6})\s');

  /// The first field of `/proc/uptime` (`12345.67 54321.00`), the boot clock,
  /// or null when the text isn't in that shape.
  @visibleForTesting
  static Duration? parseUptime(String text) {
    final RegExpMatch? match = _uptimeLine.firstMatch(text);
    if (match == null) return null;
    return Duration(
      seconds: int.parse(match[1]!),
      microseconds: int.parse(match[2]!.padRight(6, '0')),
    );
  }
}
