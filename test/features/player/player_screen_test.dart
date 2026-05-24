import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/playback_controller.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';

import 'fake_playback_controller.dart';

Future<void> _pumpScreen(
  WidgetTester tester,
  PlaybackController controller,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playbackControllerProvider.overrideWithValue(controller),
      ],
      child: const MaterialApp(home: PlayerScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('PlayerScreen', () {
    testWidgets('shows the empty state when nothing is loaded', (tester) async {
      await _pumpScreen(tester, FakePlaybackController());

      expect(find.text('Nothing playing'), findsOneWidget);
    });

    testWidgets('shows the current track title, artist, and Playing status', (
      tester,
    ) async {
      final controller = FakePlaybackController(
        initial: const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: Track(
            id: '1',
            title: 'Song One',
            uri: '/music/song1.mp3',
            artistName: 'Artist A',
          ),
        ),
      );
      await _pumpScreen(tester, controller);

      expect(find.text('Song One'), findsOneWidget);
      expect(find.text('Artist A'), findsOneWidget);
      expect(find.text('Playing'), findsOneWidget);
      // While playing, the toggle offers Pause.
      expect(find.byTooltip('Pause'), findsOneWidget);
    });

    testWidgets('the play/pause button delegates to the controller', (
      tester,
    ) async {
      final controller = FakePlaybackController(
        initial: const PlaybackState(
          status: PlaybackStatus.paused,
          currentTrack: Track(id: '1', title: 'Song One', uri: '/s.mp3'),
        ),
      );
      await _pumpScreen(tester, controller);

      // Paused: tapping the toggle resumes playback.
      await tester.tap(find.byTooltip('Play'));
      expect(controller.playCount, 1);

      // Stop is always available.
      await tester.tap(find.byTooltip('Stop'));
      expect(controller.stopCount, 1);
    });

    testWidgets('shows the Up next list and an enabled Next button', (
      tester,
    ) async {
      final controller = FakePlaybackController(
        initial: const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: Track(id: '1', title: 'Song One', uri: '/1.mp3'),
          upNext: <Track>[
            Track(id: '2', title: 'Song Two', uri: '/2.mp3'),
            Track(id: '3', title: 'Song Three', uri: '/3.mp3'),
          ],
        ),
      );
      await _pumpScreen(tester, controller);

      expect(find.text('Up next'), findsOneWidget);
      expect(find.text('Song Two'), findsOneWidget);
      expect(find.text('Song Three'), findsOneWidget);

      await tester.tap(find.byTooltip('Next'));
      expect(controller.skipCount, 1);
    });

    testWidgets('hides Up next and disables Next when the queue is empty', (
      tester,
    ) async {
      final controller = FakePlaybackController(
        initial: const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: Track(id: '1', title: 'Only Song', uri: '/1.mp3'),
        ),
      );
      await _pumpScreen(tester, controller);

      expect(find.text('Up next'), findsNothing);
      final next = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.skip_next),
          matching: find.byType(IconButton),
        ),
      );
      expect(next.onPressed, isNull);
    });

    testWidgets('Clear delegates to the controller', (tester) async {
      final controller = FakePlaybackController(
        initial: const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: Track(id: '1', title: 'Song One', uri: '/1.mp3'),
          upNext: <Track>[Track(id: '2', title: 'Song Two', uri: '/2.mp3')],
        ),
      );
      await _pumpScreen(tester, controller);

      await tester.tap(find.text('Clear'));
      expect(controller.clearCount, 1);
    });

    testWidgets('shows the specific error message on a playback error', (
      tester,
    ) async {
      final controller = FakePlaybackController(
        initial: const PlaybackState(
          status: PlaybackStatus.error,
          currentTrack: Track(
            id: 't1',
            title: 'Remote Song',
            uri: 'jellyfin:t1',
          ),
          errorMessage: 'Your Jellyfin session has expired.',
        ),
      );
      await _pumpScreen(tester, controller);

      expect(find.text('Remote Song'), findsOneWidget);
      expect(find.text('Your Jellyfin session has expired.'), findsOneWidget);
      // The generic fallback is not shown when a specific message exists.
      expect(find.text("Couldn't play this track"), findsNothing);
    });

    testWidgets('shows a Lyrics entry that opens a calm empty state', (
      tester,
    ) async {
      final controller = FakePlaybackController(
        initial: const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: Track(id: '1', title: 'Song One', uri: '/s.mp3'),
        ),
      );
      await _pumpScreen(tester, controller);

      // The entry point is visible on the player.
      expect(find.text('Lyrics'), findsOneWidget);

      await tester.tap(find.text('Lyrics'));
      await tester.pumpAndSettle();

      // No lyrics source yet, so it shows a calm placeholder rather than blank.
      expect(find.text('No lyrics available yet.'), findsOneWidget);
    });

    testWidgets('reacts to state pushed on the stream', (tester) async {
      final controller = FakePlaybackController();
      await _pumpScreen(tester, controller);
      expect(find.text('Nothing playing'), findsOneWidget);

      controller.emit(
        const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: Track(id: '1', title: 'Live Track', uri: '/l.mp3'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Live Track'), findsOneWidget);
      expect(find.text('Playing'), findsOneWidget);
    });
  });
}
