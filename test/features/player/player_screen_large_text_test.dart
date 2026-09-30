import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_failure.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_playback_preferences.dart';
import 'package:linthra/data/repositories/playback_preferences_provider.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';
import 'package:linthra/features/player/widgets/auto_skip_intro_panel.dart';
import 'package:linthra/features/player/widgets/playback_error_notice.dart';

import 'fake_playback_controller.dart';

const Track _track = Track(
  id: 't1',
  title: 'Remote Song',
  uri: 'jellyfin:t1',
  artistName: 'Artist',
  albumName: 'Album',
);
const Track _next = Track(id: 't2', title: 'Next Song', uri: 'jellyfin:t2');

/// The longest failure message the app has, with every recovery on offer:
/// the tallest panel the status strip can hold.
const PlaybackState _failed = PlaybackState(
  status: PlaybackStatus.error,
  currentTrack: _track,
  upNext: <Track>[_next],
  failure: PlaybackFailure(
    kind: PlaybackFailureKind.localFileUnavailable,
    message: "This track's file isn't where Linthra last saw it. It may have "
        'been moved, renamed or deleted, or the drive it is on may not be '
        'connected right now.',
    canRetry: true,
    canSkip: true,
  ),
);

Future<void> _pump(
  WidgetTester tester,
  FakePlaybackController controller, {
  required Size size,
  required double textScale,
  bool? autoSkip = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playbackControllerProvider.overrideWithValue(controller),
        // Chosen already unless a test says otherwise, so the error panel
        // shows rather than the one-time automatic skip question.
        playbackPreferencesProvider.overrideWithValue(
          InMemoryPlaybackPreferences(autoSkipUnplayable: autoSkip),
        ),
      ],
      child: MaterialApp(
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const PlayerScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // Each of these overflowed on main, clipping the panel's own buttons and
  // the transport: the column under the artwork had nowhere to go.
  final List<(Size, double)> phones = <(Size, double)>[
    (const Size(360, 780), 1.3),
    (const Size(360, 780), 2),
    (const Size(360, 640), 1.3),
    (const Size(360, 640), 2),
  ];

  for (final (Size size, double scale) in phones) {
    testWidgets(
        'a failure on a ${size.width.toInt()}x${size.height.toInt()} phone at '
        '${scale}x text keeps its recoveries reachable',
        (WidgetTester tester) async {
      final FakePlaybackController controller =
          FakePlaybackController(initial: _failed);
      await _pump(tester, controller, size: size, textScale: scale);

      expect(tester.takeException(), isNull, reason: 'nothing overflows');
      final Finder skip = find.byKey(
        PlaybackErrorNotice.keyForAction(PlaybackRecoveryAction.skip),
      );
      await tester.ensureVisible(skip);
      await tester.pumpAndSettle();
      await tester.tap(skip);
      await tester.pumpAndSettle();
      expect(controller.skipCount, 1);
    });
  }

  testWidgets(
      'the automatic skip question on a small phone at 2x text keeps its '
      'answers reachable', (WidgetTester tester) async {
    final FakePlaybackController controller =
        FakePlaybackController(initial: _failed);
    await _pump(
      tester,
      controller,
      size: const Size(360, 640),
      textScale: 2,
      autoSkip: null,
    );

    expect(tester.takeException(), isNull, reason: 'nothing overflows');
    final Finder allow = find.byKey(AutoSkipIntroPanel.allowKey);
    await tester.ensureVisible(allow);
    await tester.pumpAndSettle();
    await tester.tap(allow);
    await tester.pumpAndSettle();
    expect(controller.skipCount, 1);
  });

  testWidgets('a short, wide window at a large text size scrolls too',
      (WidgetTester tester) async {
    final FakePlaybackController controller =
        FakePlaybackController(initial: _failed);
    await _pump(
      tester,
      controller,
      size: const Size(1200, 560),
      textScale: 2,
    );

    expect(tester.takeException(), isNull);
    final Finder retry = find.byKey(
      PlaybackErrorNotice.keyForAction(PlaybackRecoveryAction.retry),
    );
    await tester.ensureVisible(retry);
    await tester.pumpAndSettle();
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(controller.retryCount, 1);
  });

  testWidgets('when everything fits, nothing scrolls and nothing moves',
      (WidgetTester tester) async {
    await _pump(
      tester,
      FakePlaybackController(
        initial: const PlaybackState(
          status: PlaybackStatus.paused,
          currentTrack: _track,
        ),
      ),
      size: const Size(400, 850),
      textScale: 1,
    );

    expect(tester.takeException(), isNull);
    for (final ScrollableState scrollable
        in tester.stateList<ScrollableState>(find.byType(Scrollable))) {
      if (scrollable.axisDirection != AxisDirection.down) continue;
      expect(scrollable.position.maxScrollExtent, 0,
          reason: 'the controls fit, so they must not become a scroll area');
    }
  });
}
