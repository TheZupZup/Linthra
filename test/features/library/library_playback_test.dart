import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/library/library_screen.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';

import '../player/fake_playback_controller.dart';
import 'fake_music_library_repository.dart';

GoRouter _libraryRouter() {
  return GoRouter(
    initialLocation: AppRoutes.library,
    routes: [
      GoRoute(
        path: AppRoutes.library,
        builder: (_, __) => const LibraryScreen(),
      ),
      GoRoute(
        path: AppRoutes.player,
        builder: (_, __) => const PlayerScreen(),
      ),
    ],
  );
}

void main() {
  testWidgets('tapping a track plays it and opens the player', (tester) async {
    final controller = FakePlaybackController();
    final repository = FakeMusicLibraryRepository(
      tracks: const <Track>[
        Track(id: '1', title: 'Song One', uri: '/music/song1.mp3'),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          musicLibraryRepositoryProvider.overrideWithValue(repository),
          playbackControllerProvider.overrideWithValue(controller),
        ],
        child: MaterialApp.router(routerConfig: _libraryRouter()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Song One'));
    await tester.pumpAndSettle();

    expect(controller.playedTracks.single.id, '1');
    // The now-playing screen is shown for the tapped track.
    expect(find.text('Now Playing'), findsOneWidget);
    expect(find.text('Playing'), findsOneWidget);
  });

  testWidgets('tapping a track queues the rest of the list as up next', (
    tester,
  ) async {
    final controller = FakePlaybackController();
    final repository = FakeMusicLibraryRepository(
      tracks: const <Track>[
        Track(id: '1', title: 'Song One', uri: '/music/song1.mp3'),
        Track(id: '2', title: 'Song Two', uri: '/music/song2.mp3'),
        Track(id: '3', title: 'Song Three', uri: '/music/song3.mp3'),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          musicLibraryRepositoryProvider.overrideWithValue(repository),
          playbackControllerProvider.overrideWithValue(controller),
        ],
        child: MaterialApp.router(routerConfig: _libraryRouter()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Song One'));
    await tester.pumpAndSettle();

    expect(controller.state.currentTrack?.id, '1');
    expect(
      controller.state.upNext.map((t) => t.id).toList(),
      ['2', '3'],
    );
    // The player surfaces the queued tracks in its Up next section.
    expect(find.text('Up next'), findsOneWidget);
  });
}
