import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';

import 'fake_playback_controller.dart';

void main() {
  testWidgets('Add to playlist is reachable from the now-playing overflow',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          playbackControllerProvider.overrideWithValue(
            FakePlaybackController(
              initial: const PlaybackState(
                status: PlaybackStatus.playing,
                currentTrack:
                    Track(id: '1', title: 'Song One', uri: 'jellyfin:1'),
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: PlayerScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // Add-to-playlist now lives in the player's overflow menu.
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();

    expect(find.text('Add to playlist'), findsOneWidget);
  });
}
