import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonara/core/models/playback_state.dart';
import 'package:sonara/core/models/track.dart';
import 'package:sonara/core/services/playback_controller.dart';
import 'package:sonara/features/player/player_providers.dart';
import 'package:sonara/features/player/player_screen.dart';

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
