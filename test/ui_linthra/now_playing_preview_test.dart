import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/theme.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/player/player_screen.dart';
import 'package:linthra/ui_linthra/now_playing_preview_data.dart';
import 'package:linthra/ui_linthra/preview/now_playing_preview_screen.dart';
import 'package:linthra/ui_linthra/preview/preview_playback_controller.dart';

const _track = Track(
  id: 'x',
  title: 'Sample',
  uri: 'jellyfin:x',
  artistName: 'Artist',
  albumName: 'Album',
);

void main() {
  group('PreviewPlaybackController', () {
    test('starts from, and emits, the state it is given', () async {
      final controller = PreviewPlaybackController(
        const PlaybackState(
          status: PlaybackStatus.paused,
          currentTrack: _track,
          source: PlaybackSource.streamingDirect,
        ),
      );
      addTearDown(controller.dispose);

      expect(controller.state.currentTrack?.title, 'Sample');

      final emitted = <PlaybackState>[];
      final sub = controller.stateStream.listen(emitted.add);

      controller.load(
        const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: _track,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.status, PlaybackStatus.playing);
      expect(emitted.single.status, PlaybackStatus.playing);
      await sub.cancel();
    });

    test('play / pause / seek update the state', () async {
      final controller = PreviewPlaybackController(
        const PlaybackState(
            status: PlaybackStatus.paused, currentTrack: _track),
      );
      addTearDown(controller.dispose);

      await controller.play();
      expect(controller.state.status, PlaybackStatus.playing);

      await controller.pause();
      expect(controller.state.status, PlaybackStatus.paused);

      await controller.seek(const Duration(seconds: 42));
      expect(controller.state.position, const Duration(seconds: 42));
    });

    test('shuffle and repeat toggles update the state', () async {
      final controller = PreviewPlaybackController(
        const PlaybackState(
            status: PlaybackStatus.playing, currentTrack: _track),
      );
      addTearDown(controller.dispose);

      controller.setShuffleEnabled(true);
      expect(controller.state.shuffleEnabled, isTrue);

      controller.setRepeatMode(RepeatMode.one);
      expect(controller.state.repeatMode, RepeatMode.one);
    });

    test('queue edits stay in bounds', () async {
      final controller = PreviewPlaybackController(
        const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: _track,
          upNext: <Track>[
            Track(id: 'a', title: 'A', uri: 'jellyfin:a'),
            Track(id: 'b', title: 'B', uri: 'jellyfin:b'),
          ],
        ),
      );
      addTearDown(controller.dispose);

      controller.removeFromQueue(5); // out of range: no-op
      expect(controller.state.upNext.length, 2);

      controller.removeFromQueue(0);
      expect(controller.state.upNext.single.id, 'b');

      controller.clearQueue();
      expect(controller.state.upNext, isEmpty);
    });
  });

  group('NowPlayingPreviewScreen', () {
    testWidgets('renders the real PlayerScreen with the first sample',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const NowPlayingPreviewScreen(),
        ),
      );
      await tester.pumpAndSettle();

      // The dev toolbar and the genuine Now Playing screen are both present.
      expect(find.text('Now Playing — UI preview (fake data)'), findsOneWidget);
      expect(find.byType(PlayerScreen), findsOneWidget);

      // The first sample's metadata flows through to the real widgets.
      final first = nowPlayingPreviewSamples.first.state.currentTrack!;
      expect(find.text(first.title), findsOneWidget);

      // No broken-image or layout exceptions from the fake data / generated art.
      expect(tester.takeException(), isNull);
    });
  });
}
