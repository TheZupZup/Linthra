import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/player/mini_player.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';

import 'fake_playback_controller.dart';

const _track = Track(
  id: '1',
  title: 'Song One',
  uri: '/music/song1.mp3',
  artistName: 'Artist A',
  albumName: 'Album B',
);

GoRouter _router() {
  return GoRouter(
    initialLocation: AppRoutes.library,
    routes: [
      // A stand-in main screen that hosts the mini-player exactly as the shell
      // does: pinned above the (here, omitted) navigation bar.
      GoRoute(
        path: AppRoutes.library,
        builder: (_, __) => const Scaffold(
          body: SizedBox.expand(),
          bottomNavigationBar: MiniPlayer(),
        ),
      ),
      GoRoute(
        path: AppRoutes.player,
        builder: (_, __) => const PlayerScreen(),
      ),
    ],
  );
}

Future<void> _pump(WidgetTester tester, FakePlaybackController controller) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        playbackControllerProvider.overrideWithValue(controller),
      ],
      child: MaterialApp.router(routerConfig: _router()),
    ),
  );
}

void main() {
  group('MiniPlayer', () {
    testWidgets('is hidden when nothing is playing', (tester) async {
      await _pump(tester, FakePlaybackController());
      await tester.pumpAndSettle();

      expect(find.byType(MiniPlayer), findsOneWidget);
      // Nothing loaded: it collapses, showing no track text or controls.
      expect(find.text('Song One'), findsNothing);
      expect(find.byTooltip('Play'), findsNothing);
    });

    testWidgets('appears with title and artist when a track is active', (
      tester,
    ) async {
      final controller = FakePlaybackController(
        initial: const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: _track,
        ),
      );
      await _pump(tester, controller);
      await tester.pumpAndSettle();

      expect(find.text('Song One'), findsOneWidget);
      expect(find.text('Artist A • Album B'), findsOneWidget);
      // While playing it offers a Pause control.
      expect(find.byTooltip('Pause'), findsOneWidget);
    });

    testWidgets('play/pause delegates to the controller', (tester) async {
      final controller = FakePlaybackController(
        initial: const PlaybackState(
          status: PlaybackStatus.paused,
          currentTrack: _track,
        ),
      );
      await _pump(tester, controller);
      await tester.pumpAndSettle();

      // Paused: the toggle resumes playback through the controller.
      await tester.tap(find.byTooltip('Play'));
      expect(controller.playCount, 1);

      // Reflect the resumed state and confirm the toggle now pauses.
      controller.emit(
        const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: _track,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Pause'));
      expect(controller.pauseCount, 1);
    });

    testWidgets('tapping the bar opens the full player screen', (tester) async {
      final controller = FakePlaybackController(
        initial: const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: _track,
        ),
      );
      await _pump(tester, controller);
      await tester.pumpAndSettle();

      // Tap the body (the title), not the play/pause button.
      await tester.tap(find.text('Song One'));
      await tester.pumpAndSettle();

      expect(find.text('Now Playing'), findsOneWidget);
    });
  });
}
