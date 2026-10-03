import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/sleep_timer_controller.dart';

import 'fake_playback_controller.dart';

/// A hand-driven [Timer] so a test advances the sleep-timer countdown tick by
/// tick, with no real time passing. Stands in for `Timer.periodic`.
class _FakePeriodicTimer implements Timer {
  _FakePeriodicTimer(this._onTick);

  final void Function(Timer) _onTick;
  bool _active = true;
  int _tick = 0;

  /// Fires one tick, as `Timer.periodic` would, while still active.
  void fire() {
    if (!_active) return;
    _tick++;
    _onTick(this);
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;
}

void main() {
  group('SleepTimerController', () {
    late FakePlaybackController playback;
    late ProviderContainer container;
    _FakePeriodicTimer? created;

    // Builds the controller under test with a hand-driven periodic timer,
    // recording the created timer into [created] so the test can fire its ticks.
    SleepTimerController createController() {
      return SleepTimerController(
        createPeriodic: (Duration _, void Function(Timer) onTick) {
          final timer = _FakePeriodicTimer(onTick);
          created = timer;
          return timer;
        },
      );
    }

    setUp(() {
      playback = FakePlaybackController(
        initial: const PlaybackState(status: PlaybackStatus.playing),
      );
      created = null;
      container = ProviderContainer(
        overrides: <Override>[
          playbackControllerProvider.overrideWithValue(playback),
          sleepTimerControllerProvider.overrideWith(createController),
        ],
      );
      addTearDown(container.dispose);
    });

    SleepTimerController controller() =>
        container.read(sleepTimerControllerProvider.notifier);
    SleepTimerState read() => container.read(sleepTimerControllerProvider);

    test('starts inactive', () {
      expect(read(), SleepTimerState.inactive);
      expect(read().isActive, isFalse);
      expect(created, isNull);
    });

    test('start arms the countdown with the full duration', () {
      controller().start(const Duration(minutes: 5));

      expect(read().isActive, isTrue);
      expect(read().total, const Duration(minutes: 5));
      expect(read().remaining, const Duration(minutes: 5));
      expect(created, isNotNull);
      expect(created!.isActive, isTrue);
      expect(playback.pauseCount, 0);
    });

    test('each tick decrements the remaining time', () {
      controller().start(const Duration(minutes: 1));

      created!.fire();
      expect(read().remaining, const Duration(seconds: 59));
      created!.fire();
      expect(read().remaining, const Duration(seconds: 58));
      // The total is unchanged while counting down.
      expect(read().total, const Duration(minutes: 1));
      expect(playback.pauseCount, 0);
    });

    test('expiry pauses playback and clears the timer', () {
      controller().start(const Duration(seconds: 3));

      created!.fire(); // 3s -> 2s
      created!.fire(); // 2s -> 1s
      expect(read().isActive, isTrue);
      expect(playback.pauseCount, 0);

      created!.fire(); // 1s -> 0s => expiry
      expect(read(), SleepTimerState.inactive);
      expect(read().isActive, isFalse);
      expect(playback.pauseCount, 1);
      // The periodic timer is cancelled, so it never ticks again.
      expect(created!.isActive, isFalse);
    });

    test('cancel stops the countdown without pausing playback', () {
      controller().start(const Duration(minutes: 10));
      final _FakePeriodicTimer armed = created!;

      controller().cancel();

      expect(read().isActive, isFalse);
      expect(armed.isActive, isFalse);
      expect(playback.pauseCount, 0);
    });

    test('cancel is a no-op when no timer is running', () {
      controller().cancel();

      expect(read().isActive, isFalse);
      expect(playback.pauseCount, 0);
    });

    test('start replaces an existing countdown', () {
      controller().start(const Duration(minutes: 5));
      final _FakePeriodicTimer first = created!;

      controller().start(const Duration(minutes: 20));

      // The previous timer is cancelled and a fresh one armed for the new delay.
      expect(first.isActive, isFalse);
      expect(identical(created, first), isFalse);
      expect(created!.isActive, isTrue);
      expect(read().total, const Duration(minutes: 20));
      expect(read().remaining, const Duration(minutes: 20));
    });

    test('start ignores a non-positive duration', () {
      controller().start(Duration.zero);

      expect(read().isActive, isFalse);
      expect(created, isNull);

      controller().start(const Duration(seconds: -5));
      expect(read().isActive, isFalse);
      expect(created, isNull);
    });

    test('a stray tick after cancel changes nothing', () {
      controller().start(const Duration(minutes: 1));
      final _FakePeriodicTimer armed = created!;
      controller().cancel();

      // Even if a tick somehow fires after cancellation, it must not resurrect
      // the countdown or pause playback. (fire() respects cancel, so force it.)
      armed._active = true;
      armed.fire();

      expect(read().isActive, isFalse);
      expect(playback.pauseCount, 0);
    });

    group('while the computer sleeps', () {
      // Dart's timers run on the monotonic clock, which stands still while a
      // Linux machine is suspended (and while an Android phone is in deep
      // sleep): after the wake the periodic timer simply delivers the tick
      // after the last one. Only the wall clock knows the night went by.
      late DateTime wall;

      SleepTimerController withWallClock() {
        return SleepTimerController(
          createPeriodic: (Duration _, void Function(Timer) onTick) {
            final timer = _FakePeriodicTimer(onTick);
            created = timer;
            return timer;
          },
          now: () => wall,
        );
      }

      setUp(() {
        wall = DateTime.utc(2026, 10, 3, 23);
        container = ProviderContainer(
          overrides: <Override>[
            playbackControllerProvider.overrideWithValue(playback),
            sleepTimerControllerProvider.overrideWith(withWallClock),
          ],
        );
        addTearDown(container.dispose);
      });

      /// One second of real time, as the periodic timer delivers it.
      void tickOneSecond() {
        wall = wall.add(const Duration(seconds: 1));
        created!.fire();
      }

      test(
          'a countdown that ran out while the laptop was suspended pauses as '
          'soon as it wakes', () {
        controller().start(const Duration(minutes: 30));
        for (int i = 0; i < 20 * 60; i++) {
          tickOneSecond();
        }
        expect(read().remaining, const Duration(minutes: 10));
        expect(playback.pauseCount, 0);

        // The laptop suspends (the lid closes, or it goes to sleep on its own
        // after a while with no input) and wakes up the next morning, where
        // the music it was playing carries on.
        wall = wall.add(const Duration(hours: 8));
        tickOneSecond();

        expect(
          playback.pauseCount,
          1,
          reason: 'the 30 minutes ran out during the night; the music must not '
              'play on for the 10 minutes the countdown still showed',
        );
        expect(read().isActive, isFalse);
        expect(created!.isActive, isFalse);
      });

      test('a shorter sleep is taken off what is left', () {
        controller().start(const Duration(minutes: 30));
        for (int i = 0; i < 5 * 60; i++) {
          tickOneSecond();
        }
        expect(read().remaining, const Duration(minutes: 25));

        wall = wall.add(const Duration(minutes: 10));
        tickOneSecond();

        expect(read().remaining, const Duration(minutes: 14, seconds: 59));
        expect(playback.pauseCount, 0);

        for (int i = 0; i < 14 * 60 + 58; i++) {
          tickOneSecond();
        }
        expect(read().remaining, const Duration(seconds: 1));
        expect(playback.pauseCount, 0);
        tickOneSecond();
        expect(playback.pauseCount, 1);
        expect(read().isActive, isFalse);
      });

      test('a custom delay past the end of the calendar still counts down', () {
        controller().start(const Duration(minutes: 5));
        // The custom field takes any whole number of minutes; this one ends
        // past the last date a DateTime can hold.
        const Duration absurd = Duration(minutes: 150000000000);

        controller().start(absurd);
        expect(read().remaining, absurd);
        tickOneSecond();

        expect(read().isActive, isTrue);
        expect(read().remaining, absurd - const Duration(seconds: 1));
        expect(playback.pauseCount, 0);
      });

      test('a clock set back does not make the countdown longer', () {
        controller().start(const Duration(minutes: 2));
        tickOneSecond();

        wall = wall.subtract(const Duration(hours: 1));
        tickOneSecond();

        expect(read().remaining, const Duration(minutes: 1, seconds: 58));
      });
    });
  });
}
