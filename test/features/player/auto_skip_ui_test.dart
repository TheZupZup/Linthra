import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_failure.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_playback_preferences.dart';
import 'package:linthra/data/repositories/playback_preferences_provider.dart';
import 'package:linthra/features/player/mini_player.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';
import 'package:linthra/features/player/widgets/auto_skip_intro_panel.dart';
import 'package:linthra/features/player/widgets/auto_skip_notice.dart';
import 'package:linthra/features/player/widgets/playback_error_notice.dart';

import 'fake_playback_controller.dart';

const Track _track = Track(id: 't1', title: 'Remote Song', uri: 'jellyfin:t1');
const Track _next = Track(id: 't2', title: 'Next Song', uri: 'jellyfin:t2');

const PlaybackFailure _unreachable = PlaybackFailure(
  kind: PlaybackFailureKind.temporarySource,
  message: "Couldn't reach your Jellyfin server.",
  canRetry: true,
  canSkip: true,
);

PlaybackState _failed({
  PlaybackFailure failure = _unreachable,
  RepeatMode repeatMode = RepeatMode.off,
}) =>
    PlaybackState(
      status: PlaybackStatus.error,
      currentTrack: _track,
      upNext: const <Track>[_next],
      repeatMode: repeatMode,
      failure: failure,
    );

PlaybackState _countingDown(DateTime skipsAt) => PlaybackState(
      status: PlaybackStatus.loading,
      currentTrack: _track,
      upNext: const <Track>[_next],
      autoSkip: PendingAutoSkip(
        failure: _unreachable,
        skipsAt: skipsAt,
        countdown: const Duration(seconds: 5),
      ),
    );

/// Pumps the now-playing screen. A countdown keeps repainting and a busy
/// status shows a spinner, so neither ever "settles": [settle] false pumps a
/// few frames instead.
Future<InMemoryPlaybackPreferences> _pumpPlayer(
  WidgetTester tester,
  FakePlaybackController controller, {
  bool? autoSkip,
  bool settle = true,
}) async {
  final InMemoryPlaybackPreferences preferences =
      InMemoryPlaybackPreferences(autoSkipUnplayable: autoSkip);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playbackControllerProvider.overrideWithValue(controller),
        playbackPreferencesProvider.overrideWithValue(preferences),
      ],
      child: const MaterialApp(home: PlayerScreen()),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
  return preferences;
}

void main() {
  group('the first failure explains automatic skip, once', () {
    testWidgets('asks, with the reason, while the listener has not chosen',
        (WidgetTester tester) async {
      await _pumpPlayer(
        tester,
        FakePlaybackController(initial: _failed()),
      );

      expect(find.byKey(AutoSkipIntroPanel.panelKey), findsOneWidget);
      expect(
          find.text("Sorry, Linthra couldn't play this song"), findsOneWidget);
      expect(find.text("Couldn't reach your Jellyfin server."), findsOneWidget);
      expect(find.textContaining('automatically move to the next song'),
          findsOneWidget);
      expect(find.text('Allow automatic skip'), findsOneWidget);
      expect(find.text('Not now'), findsOneWidget);
      expect(find.text('Details'), findsOneWidget);
      // Nothing pre-selected, nothing that looks like consent already given.
      expect(find.byType(Switch), findsNothing);
      expect(find.byType(Checkbox), findsNothing);
      expect(find.byKey(PlaybackErrorNotice.noticeKey), findsNothing);
    });

    testWidgets('never asks again once the listener has chosen',
        (WidgetTester tester) async {
      for (final bool choice in <bool>[false, true]) {
        await _pumpPlayer(
          tester,
          FakePlaybackController(initial: _failed()),
          autoSkip: choice,
        );
        expect(find.byKey(AutoSkipIntroPanel.panelKey), findsNothing,
            reason: 'chosen: $choice');
        expect(find.byKey(PlaybackErrorNotice.noticeKey), findsOneWidget);
      }
    });

    testWidgets('does not ask about a failure a skip could not get past',
        (WidgetTester tester) async {
      // Last in the queue, an engine failure, and repeat-one: automatic skip
      // would not move on from any of these, so it isn't offered.
      final List<PlaybackState> states = <PlaybackState>[
        _failed(
          failure: const PlaybackFailure(
            kind: PlaybackFailureKind.temporarySource,
            message: "Couldn't reach your Jellyfin server.",
            canRetry: true,
          ),
        ),
        _failed(
          failure: const PlaybackFailure(
            kind: PlaybackFailureKind.playbackEngineUnavailable,
            message: 'The audio engine is not available.',
            canRetry: true,
          ),
        ),
        _failed(repeatMode: RepeatMode.one),
      ];
      for (final PlaybackState state in states) {
        await _pumpPlayer(tester, FakePlaybackController(initial: state));
        expect(find.byKey(AutoSkipIntroPanel.panelKey), findsNothing);
        expect(find.byKey(PlaybackErrorNotice.noticeKey), findsOneWidget);
      }
    });

    testWidgets('Allow saves the choice and moves on, once',
        (WidgetTester tester) async {
      final FakePlaybackController controller =
          FakePlaybackController(initial: _failed());
      final InMemoryPlaybackPreferences preferences =
          await _pumpPlayer(tester, controller);

      await tester.tap(find.byKey(AutoSkipIntroPanel.allowKey));
      await tester.tap(find.byKey(AutoSkipIntroPanel.allowKey),
          warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(await preferences.autoSkipUnplayable(), isTrue);
      expect(controller.skipCount, 1,
          reason: 'a double tap must not move the queue twice');
    });

    testWidgets('Not now saves the choice and leaves the usual recoveries',
        (WidgetTester tester) async {
      final FakePlaybackController controller =
          FakePlaybackController(initial: _failed());
      final InMemoryPlaybackPreferences preferences =
          await _pumpPlayer(tester, controller);

      await tester.tap(find.byKey(AutoSkipIntroPanel.notNowKey));
      await tester.pumpAndSettle();

      expect(await preferences.autoSkipUnplayable(), isFalse);
      expect(controller.skipCount, 0);
      expect(find.byKey(AutoSkipIntroPanel.panelKey), findsNothing);
      expect(find.byKey(PlaybackErrorNotice.noticeKey), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Skip'), findsOneWidget);
    });

    testWidgets('Details says what happened and where to change it later',
        (WidgetTester tester) async {
      await _pumpPlayer(tester, FakePlaybackController(initial: _failed()));

      await tester.tap(find.byKey(AutoSkipIntroPanel.detailsKey));
      await tester.pumpAndSettle();

      expect(find.text('What happened: Playback problem.'), findsOneWidget);
      expect(find.textContaining('Settings, under Playback'), findsOneWidget);
      expect(find.text('Hide details'), findsOneWidget);
    });

    testWidgets('keeps every choice on screen at a large text size',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            playbackControllerProvider.overrideWithValue(
              FakePlaybackController(initial: _failed()),
            ),
            playbackPreferencesProvider
                .overrideWithValue(InMemoryPlaybackPreferences()),
          ],
          child: const MediaQuery(
            data: MediaQueryData(
              size: Size(360, 780),
              textScaler: TextScaler.linear(2),
            ),
            child: MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: AutoSkipIntroPanel(failure: _unreachable),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      for (final Key key in <Key>[
        AutoSkipIntroPanel.allowKey,
        AutoSkipIntroPanel.notNowKey,
        AutoSkipIntroPanel.detailsKey,
      ]) {
        final Rect rect = tester.getRect(find.byKey(key));
        expect(rect.right, lessThanOrEqualTo(360), reason: '$key');
      }
    });
  });

  group('a failure panel on a short screen at a large text size', () {
    Future<void> pumpShortScreen(
      WidgetTester tester,
      FakePlaybackController controller, {
      bool? autoSkip,
    }) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            playbackControllerProvider.overrideWithValue(controller),
            playbackPreferencesProvider.overrideWithValue(
              InMemoryPlaybackPreferences(autoSkipUnplayable: autoSkip),
            ),
          ],
          child: MaterialApp(
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const PlayerScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the explanation with details open never overflows the screen',
        (WidgetTester tester) async {
      await pumpShortScreen(tester, FakePlaybackController(initial: _failed()));
      await tester.ensureVisible(find.byKey(AutoSkipIntroPanel.detailsKey));
      await tester.tap(find.byKey(AutoSkipIntroPanel.detailsKey));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // Every choice can still be reached.
      await tester.ensureVisible(find.byKey(AutoSkipIntroPanel.allowKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(AutoSkipIntroPanel.allowKey));
      await tester.pumpAndSettle();
    });

    testWidgets('the error panel keeps its recoveries reachable',
        (WidgetTester tester) async {
      final FakePlaybackController controller = FakePlaybackController(
        initial: _failed(
          failure: const PlaybackFailure(
            kind: PlaybackFailureKind.localFileUnavailable,
            message: "This track's file isn't where Linthra last saw it. It "
                'may have been moved, renamed or deleted, or the drive it is '
                'on may not be connected right now.',
            canRetry: true,
            canSkip: true,
          ),
        ),
      );
      await pumpShortScreen(tester, controller, autoSkip: false);

      expect(tester.takeException(), isNull);
      await tester.ensureVisible(
        find.byKey(
          PlaybackErrorNotice.keyForAction(PlaybackRecoveryAction.skip),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          PlaybackErrorNotice.keyForAction(PlaybackRecoveryAction.skip),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.skipCount, 1);
    });
  });

  group('the countdown before an automatic skip', () {
    testWidgets('shows the reason and the seconds the controller published',
        (WidgetTester tester) async {
      final DateTime now = DateTime(2026, 9, 30, 12);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            playbackControllerProvider.overrideWithValue(
              FakePlaybackController(initial: _countingDown(now)),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: AutoSkipNotice(
                autoSkip: _countingDown(now.add(const Duration(seconds: 4)))
                    .autoSkip!,
                now: () => now,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text("Couldn't reach your Jellyfin server."), findsOneWidget);
      expect(
          find.text('Skipping to the next song in 4 seconds.'), findsOneWidget);
      expect(find.text('Stay on this track'), findsOneWidget);
    });

    testWidgets('takes the status strip on the now-playing screen',
        (WidgetTester tester) async {
      await _pumpPlayer(
        tester,
        FakePlaybackController(
          initial:
              _countingDown(DateTime.now().add(const Duration(minutes: 1))),
        ),
        autoSkip: true,
        settle: false,
      );

      expect(find.byKey(AutoSkipNotice.noticeKey), findsOneWidget);
      expect(find.byKey(PlaybackErrorNotice.noticeKey), findsNothing);
      expect(find.byKey(AutoSkipIntroPanel.panelKey), findsNothing);
    });

    testWidgets('Stay on this track asks the controller once',
        (WidgetTester tester) async {
      final FakePlaybackController controller = FakePlaybackController(
        initial: _countingDown(DateTime.now().add(const Duration(minutes: 1))),
      );
      await _pumpPlayer(tester, controller, autoSkip: true, settle: false);

      await tester.tap(find.byKey(AutoSkipNotice.stayKey));
      await tester.tap(find.byKey(AutoSkipNotice.stayKey), warnIfMissed: false);
      await tester.pump();

      expect(controller.cancelAutoSkipCount, 1);
    });

    testWidgets('disappears the moment the controller calls the skip off',
        (WidgetTester tester) async {
      final FakePlaybackController controller = FakePlaybackController(
        initial: _countingDown(DateTime.now().add(const Duration(minutes: 1))),
      );
      await _pumpPlayer(tester, controller, autoSkip: true, settle: false);
      expect(find.byKey(AutoSkipNotice.noticeKey), findsOneWidget);

      controller.emit(_failed());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(AutoSkipNotice.noticeKey), findsNothing);
      expect(find.byKey(PlaybackErrorNotice.noticeKey), findsOneWidget);
    });

    testWidgets('is announced to a screen reader once, not every second',
        (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await _pumpPlayer(
        tester,
        FakePlaybackController(
          initial:
              _countingDown(DateTime.now().add(const Duration(minutes: 1))),
        ),
        autoSkip: true,
        settle: false,
      );

      expect(
        find.bySemanticsLabel(RegExp('Linthra will skip to the next song')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel(RegExp(r'in \d+ seconds')), findsNothing);
      semantics.dispose();
    });

    testWidgets('the mini-player says a skip is coming',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            playbackControllerProvider.overrideWithValue(
              FakePlaybackController(
                initial: _countingDown(
                  DateTime.now().add(const Duration(minutes: 1)),
                ),
              ),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: MiniPlayer(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Playback problem, skipping to the next song'),
          findsOneWidget);
    });
  });
}
