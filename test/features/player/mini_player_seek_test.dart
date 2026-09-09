import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/features/player/mini_player.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/widgets/playback_progress_bar.dart';

import 'fake_playback_controller.dart';

/// The now-playing bar's top edge is a readout on a phone and a control on a
/// desktop. That split is the whole point: a pointer can aim at a slim line and
/// a thumb cannot, and on a phone that strip is exactly where a thumb lands
/// reaching for the bar itself.
const _track = Track(
  id: '1',
  title: 'Song One',
  uri: 'subsonic:1',
  artistName: 'Artist A',
  albumName: 'Album B',
);

const _state = PlaybackState(
  status: PlaybackStatus.playing,
  currentTrack: _track,
  position: Duration.zero,
  duration: Duration(minutes: 4),
);

Future<void> _pump(
  WidgetTester tester, {
  required HostPlatform host,
  double width = 1280,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 800);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        hostPlatformProvider.overrideWithValue(host),
        playbackControllerProvider
            .overrideWithValue(FakePlaybackController(initial: _state)),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(),
          bottomNavigationBar: MiniPlayer(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

FakePlaybackController _controller(WidgetTester tester) {
  return ProviderScope.containerOf(
    tester.element(find.byType(MiniPlayer)),
  ).read(playbackControllerProvider) as FakePlaybackController;
}

void main() {
  group('MiniPlayer seeking', () {
    testWidgets('a click along the line seeks there on a desktop host',
        (tester) async {
      await _pump(tester, host: HostPlatform.linux);

      final Rect bar = tester.getRect(find.byType(PlaybackProgressBar));
      // Three quarters of the way along a four-minute track.
      await tester.tapAt(Offset(bar.left + bar.width * 0.75, bar.center.dy));
      await tester.pumpAndSettle();

      final List<Duration> seeks = _controller(tester).seeks;
      expect(seeks, hasLength(1));
      // The exact millisecond depends on the marker inset the painter reserves,
      // so this pins the quarter it landed in rather than a hard-coded value.
      expect(
          seeks.single, greaterThan(const Duration(minutes: 2, seconds: 40)));
      expect(seeks.single, lessThan(const Duration(minutes: 3, seconds: 20)));
    });

    testWidgets('the arrow keys seek once the line has focus', (tester) async {
      await _pump(tester, host: HostPlatform.linux);

      final Rect bar = tester.getRect(find.byType(PlaybackProgressBar));
      // Clicking hands the line the keyboard, exactly as it does in the full
      // player, so the arrows carry on from where the pointer left off.
      await tester.tapAt(Offset(bar.left + 1, bar.center.dy));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      final List<Duration> seeks = _controller(tester).seeks;
      expect(seeks, hasLength(2));
      // 5% of four minutes, forward from the start the click set.
      expect(seeks.last, greaterThan(seeks.first));
      expect(seeks.last, lessThan(const Duration(seconds: 30)));
    });

    testWidgets('a touch host keeps the plain, unseekable line',
        (tester) async {
      await _pump(tester, host: HostPlatform.android, width: 411);

      expect(find.byType(PlaybackProgressBar), findsNothing);
      expect(_controller(tester).seeks, isEmpty);
    });

    testWidgets('a wide touch window is still not a seek surface',
        (tester) async {
      // Width alone must not turn it into a control: an Android tablet in
      // landscape is as wide as a desktop window and still driven by a thumb.
      await _pump(tester, host: HostPlatform.android, width: 1280);

      expect(find.byType(PlaybackProgressBar), findsNothing);
    });
  });
}
