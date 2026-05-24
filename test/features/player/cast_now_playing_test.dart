import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/cast_playback_status.dart';
import 'package:linthra/core/models/cast_state.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/active_playback_controller.dart';
import 'package:linthra/features/player/cast/cast_providers.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';

import 'cast/fake_cast_service.dart';
import 'fake_playback_controller.dart';

const _track = Track(
  id: 'a',
  title: 'Song A',
  uri: 'jellyfin:a',
  artistName: 'Artist',
);
const _device = CastDevice(id: 'd1', name: 'Living Room');

PlaybackState _playing() => const PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: _track,
    );

void main() {
  group('Now Playing reflects the cast session', () {
    testWidgets('shows a "Casting to <device>" indicator when connected',
        (tester) async {
      final cast = FakeCastService(
        initial: const CastState(
          availability: CastAvailability.connected,
          devices: <CastDevice>[_device],
          connectedDevice: _device,
          isCasting: true,
        ),
      );
      addTearDown(cast.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playbackControllerProvider
                .overrideWithValue(FakePlaybackController(initial: _playing())),
            castServiceProvider.overrideWithValue(cast),
          ],
          child: const MaterialApp(home: PlayerScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Casting to Living Room'), findsOneWidget);
      // The connected glyph is shown (the cast button uses it too).
      expect(find.byIcon(Icons.cast_connected), findsWidgets);
    });

    testWidgets('shows the source badge (not a cast indicator) when local',
        (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playbackControllerProvider
                .overrideWithValue(FakePlaybackController(initial: _playing())),
          ],
          child: const MaterialApp(home: PlayerScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Casting to'), findsNothing);
    });
  });

  group('opening Lyrics never starts local playback', () {
    testWidgets('local playback: opening Lyrics does not call play',
        (tester) async {
      final controller = FakePlaybackController(initial: _playing());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playbackControllerProvider.overrideWithValue(controller),
          ],
          child: const MaterialApp(home: PlayerScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Lyrics'));
      await tester.pumpAndSettle();

      expect(controller.playCount, 0);
    });

    testWidgets('while casting: opening Lyrics neither plays nor resumes local',
        (tester) async {
      final local = FakePlaybackController(initial: _playing());
      final cast = FakeCastService();
      addTearDown(cast.dispose);
      final router = ActivePlaybackController(local: local, cast: cast);
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playbackControllerProvider.overrideWithValue(router),
            castServiceProvider.overrideWithValue(cast),
          ],
          child: const MaterialApp(home: PlayerScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // Hand off to the receiver (paused, so no interpolation ticker runs).
      cast.emit(const CastState(
        availability: CastAvailability.connected,
        devices: <CastDevice>[_device],
        connectedDevice: _device,
        isCasting: true,
      ));
      cast.emitPlayback(const CastPlaybackStatus(
        status: PlaybackStatus.paused,
        position: Duration(seconds: 5),
        duration: Duration(minutes: 3),
      ));
      await tester.pumpAndSettle();
      final int playsBefore = local.playCount;
      final int resumesBefore = local.resumeCount;

      await tester.tap(find.byTooltip('Lyrics'));
      await tester.pumpAndSettle();

      expect(local.playCount, playsBefore);
      expect(local.resumeCount, resumesBefore);
    });
  });
}
