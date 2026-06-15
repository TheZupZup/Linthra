import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/player/sleep_timer_controller.dart';
import 'package:linthra/features/player/widgets/now_playing_actions.dart';
import 'package:linthra/features/player/widgets/sleep_timer_sheet.dart';

/// An inert [Timer] that never fires, so arming the countdown in a widget test
/// schedules no real timers (which would otherwise leave the test pending).
class _InertTimer implements Timer {
  bool _active = true;

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

Timer _noopPeriodic(Duration _, void Function(Timer) __) => _InertTimer();

/// Pumps the sheet with a controller whose countdown never ticks, so a test can
/// arm a timer and assert the running view without real time passing.
Future<void> _pumpSheet(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        sleepTimerControllerProvider.overrideWith(
          () => SleepTimerController(createPeriodic: _noopPeriodic),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: SleepTimerSheet())),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('SleepTimerSheet', () {
    testWidgets('shows the delay presets when idle', (tester) async {
      await _pumpSheet(tester);

      expect(find.text('5 min'), findsOneWidget);
      expect(find.text('10 min'), findsOneWidget);
      expect(find.text('15 min'), findsOneWidget);
      expect(find.text('20 min'), findsOneWidget);
      expect(find.text('Custom'), findsOneWidget);
      expect(find.text('Cancel timer'), findsNothing);
    });

    testWidgets('tapping a preset arms the timer and shows the countdown',
        (tester) async {
      await _pumpSheet(tester);

      await tester.tap(find.text('15 min'));
      await tester.pumpAndSettle();

      expect(find.text('15:00'), findsOneWidget);
      expect(find.text('Cancel timer'), findsOneWidget);
      // The presets give way to the running view.
      expect(find.text('5 min'), findsNothing);
    });

    testWidgets('Cancel timer returns to the presets', (tester) async {
      await _pumpSheet(tester);

      await tester.tap(find.text('20 min'));
      await tester.pumpAndSettle();
      expect(find.text('20:00'), findsOneWidget);

      await tester.tap(find.text('Cancel timer'));
      await tester.pumpAndSettle();

      expect(find.text('Cancel timer'), findsNothing);
      expect(find.text('5 min'), findsOneWidget);
    });

    testWidgets('the Custom option arms a custom delay', (tester) async {
      await _pumpSheet(tester);

      await tester.tap(find.text('Custom'));
      await tester.pumpAndSettle();
      expect(find.text('Custom sleep timer'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '45');
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();

      expect(find.text('45:00'), findsOneWidget);
    });

    testWidgets('an empty or zero custom value shows a validation error',
        (tester) async {
      await _pumpSheet(tester);

      await tester.tap(find.text('Custom'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '0');
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();

      // The dialog stays open with an error; no countdown was armed.
      expect(find.text('Enter a whole number of minutes.'), findsOneWidget);
      expect(find.text('Custom sleep timer'), findsOneWidget);
    });
  });

  group('NowPlayingActions sleep timer', () {
    testWidgets('includes a Sleep timer action that opens the sheet',
        (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: NowPlayingActions(
                track: Track(id: '1', title: 'Song One', uri: 'jellyfin:1'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Sleep timer'), findsOneWidget);

      await tester.tap(find.byTooltip('Sleep timer'));
      await tester.pumpAndSettle();

      // The sheet is open: the prompt and presets are visible.
      expect(find.text('Pause playback after'), findsOneWidget);
      expect(find.text('5 min'), findsOneWidget);
    });
  });

  group('formatSleepRemaining', () {
    test('formats minutes and seconds as M:SS', () {
      expect(
        formatSleepRemaining(const Duration(minutes: 4, seconds: 5)),
        '4:05',
      );
    });

    test('formats H:MM:SS past an hour', () {
      expect(
        formatSleepRemaining(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '1:02:03',
      );
    });

    test('clamps a negative remaining to zero', () {
      expect(formatSleepRemaining(const Duration(seconds: -1)), '0:00');
    });
  });
}
