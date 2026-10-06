import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/lifecycle/system_sleep_watcher.dart';

import '../../support/fake_machine_sleep.dart';

/// A Linux machine's two clocks, moved by hand: the boot clock that
/// `/proc/uptime` reads, and the monotonic one behind a Stopwatch.
class _Clocks {
  Duration boot = const Duration(hours: 5, milliseconds: 120);
  Duration monotonic = const Duration(minutes: 3);
  bool procReadable = true;

  String uptime() {
    if (!procReadable) {
      throw const FileSystemException('Cannot open file', '/proc/uptime');
    }
    final int hundredths = boot.inMilliseconds ~/ 10;
    return '${hundredths ~/ 100}.'
        '${(hundredths % 100).toString().padLeft(2, '0')} 1234.56\n';
  }

  /// Time passing while the machine is awake: both clocks move.
  void awake(Duration duration) {
    boot += duration;
    monotonic += duration;
  }

  /// A suspend: only the boot clock moves.
  void suspend(Duration duration) => boot += duration;
}

void main() {
  group('reading the boot clock', () {
    test('parses the first field of /proc/uptime', () {
      expect(
        SystemSleepWatcher.parseUptime('350735.47 234388.90\n'),
        const Duration(seconds: 350735, milliseconds: 470),
      );
      expect(SystemSleepWatcher.parseUptime('0.05 0.00\n'),
          const Duration(milliseconds: 50));
    });

    test('anything else is no reading', () {
      for (final String text in <String>[
        '',
        'uptime\n',
        '-12.00 3.00\n',
        '12 3.00\n',
        '12.00',
      ]) {
        expect(SystemSleepWatcher.parseUptime(text), isNull, reason: text);
      }
    });

    test('no readable /proc means no watcher at all', () {
      final _Clocks clocks = _Clocks()..procReadable = false;

      expect(
        SystemSleepWatcher.linuxTimeAsleep(readUptime: clocks.uptime),
        isNull,
      );
      expect(
        SystemSleepWatcher.linuxTimeAsleep(readUptime: () => 'garbage'),
        isNull,
      );
    });
  });

  group('time asleep on Linux', () {
    test('hours awake, window hidden or not, are no time asleep', () {
      final _Clocks clocks = _Clocks();
      final TimeAsleepReader timeAsleep = SystemSleepWatcher.linuxTimeAsleep(
        readUptime: clocks.uptime,
        monotonic: () => clocks.monotonic,
      )!;

      clocks.awake(const Duration(hours: 3, minutes: 7));

      expect(timeAsleep()!.abs(), lessThan(const Duration(milliseconds: 20)));
    });

    test('a suspend is the boot clock running ahead of the monotonic one', () {
      final _Clocks clocks = _Clocks();
      final TimeAsleepReader timeAsleep = SystemSleepWatcher.linuxTimeAsleep(
        readUptime: clocks.uptime,
        monotonic: () => clocks.monotonic,
      )!;

      clocks.awake(const Duration(minutes: 2));
      clocks.suspend(const Duration(minutes: 40));
      clocks.awake(const Duration(seconds: 3));

      expect(
        timeAsleep()!.inSeconds,
        const Duration(minutes: 40).inSeconds,
      );
    });

    test('a read that fails says nothing rather than something wrong', () {
      final _Clocks clocks = _Clocks();
      final TimeAsleepReader timeAsleep = SystemSleepWatcher.linuxTimeAsleep(
        readUptime: clocks.uptime,
        monotonic: () => clocks.monotonic,
      )!;

      clocks.procReadable = false;
      expect(timeAsleep(), isNull);

      clocks.procReadable = true;
      clocks.suspend(const Duration(minutes: 5));
      expect(timeAsleep()!.inMinutes, 5);
    });
  });

  group('watching', () {
    test('holds no timer until asked to look', () {
      final FakeMachineSleep machine = FakeMachineSleep();
      final SystemSleepWatcher watcher = machine.watcher();
      addTearDown(watcher.dispose);

      expect(watcher.isWatching, isFalse);
      expect(machine.isWatched, isFalse);

      watcher.watch(true);
      expect(machine.isWatched, isTrue);

      watcher.watch(false);
      expect(machine.isWatched, isFalse);
    });

    test('a sleep while looking is reported once, however often it looks',
        () async {
      final FakeMachineSleep machine = FakeMachineSleep();
      final SystemSleepWatcher watcher = machine.watcher();
      addTearDown(watcher.dispose);
      final List<Duration> wakes = <Duration>[];
      watcher.wakes.listen(wakes.add);

      watcher.watch(true);
      machine.look();
      machine.sleep(const Duration(minutes: 25));
      machine.look();
      machine.look();
      machine.look();
      await Future<void>.delayed(Duration.zero);

      expect(wakes, <Duration>[const Duration(minutes: 25)]);
    });

    test('each sleep is its own wake', () async {
      final FakeMachineSleep machine = FakeMachineSleep();
      final SystemSleepWatcher watcher = machine.watcher();
      addTearDown(watcher.dispose);
      final List<Duration> wakes = <Duration>[];
      watcher.wakes.listen(wakes.add);

      watcher.watch(true);
      machine.sleep(const Duration(minutes: 1));
      machine.look();
      machine.sleep(const Duration(hours: 8));
      machine.look();
      await Future<void>.delayed(Duration.zero);

      expect(wakes, <Duration>[
        const Duration(minutes: 1),
        const Duration(hours: 8),
      ]);
    });

    test('a sleep taken while not looking is never reported', () async {
      final FakeMachineSleep machine = FakeMachineSleep();
      final SystemSleepWatcher watcher = machine.watcher();
      addTearDown(watcher.dispose);
      final List<Duration> wakes = <Duration>[];
      watcher.wakes.listen(wakes.add);

      watcher.watch(true);
      watcher.watch(false);
      // Paused, say: the machine sleeps with nothing playing.
      machine.sleep(const Duration(hours: 2));
      watcher.watch(true);
      machine.look();
      await Future<void>.delayed(Duration.zero);

      expect(wakes, isEmpty);
    });

    test('the clocks disagreeing by a reading or two is not a sleep', () async {
      final FakeMachineSleep machine = FakeMachineSleep();
      final SystemSleepWatcher watcher = machine.watcher();
      addTearDown(watcher.dispose);
      final List<Duration> wakes = <Duration>[];
      watcher.wakes.listen(wakes.add);

      watcher.watch(true);
      machine.sleep(const Duration(milliseconds: 30));
      machine.look();
      await Future<void>.delayed(Duration.zero);

      expect(wakes, isEmpty);
    });

    test('a sleep around a failed reading is still noticed, once', () async {
      final FakeMachineSleep machine = FakeMachineSleep();
      final SystemSleepWatcher watcher = machine.watcher();
      addTearDown(watcher.dispose);
      final List<Duration> wakes = <Duration>[];
      watcher.wakes.listen(wakes.add);

      watcher.watch(true);
      machine.sleep(const Duration(minutes: 10));
      machine.unreadable = true;
      machine.look();
      machine.unreadable = false;
      machine.look();
      machine.look();
      await Future<void>.delayed(Duration.zero);

      expect(wakes, <Duration>[const Duration(minutes: 10)]);
    });

    test('tells a reading taken before a sleep from one taken after', () {
      final FakeMachineSleep machine = FakeMachineSleep();
      final SystemSleepWatcher watcher = machine.watcher();
      addTearDown(watcher.dispose);

      final Duration? before = watcher.timeAsleep();
      machine.sleep(const Duration(minutes: 3));
      final Duration? after = watcher.timeAsleep();

      expect(watcher.sleptSince(before), isTrue);
      expect(watcher.sleptSince(after), isFalse);
      expect(watcher.sleptSince(null), isFalse,
          reason: 'an unknown reading is not a sleep');
    });

    test('disposing stops looking for good', () async {
      final FakeMachineSleep machine = FakeMachineSleep();
      final SystemSleepWatcher watcher = machine.watcher();
      final Completer<void> closed = Completer<void>();
      watcher.wakes.listen(null, onDone: closed.complete);

      watcher.watch(true);
      await watcher.dispose();
      watcher.watch(true);

      expect(machine.isWatched, isFalse);
      await closed.future;
    });
  });
}
