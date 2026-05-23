import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sonara/app/routes.dart';
import 'package:sonara/core/models/track.dart';
import 'package:sonara/data/repositories/music_library_repository_provider.dart';
import 'package:sonara/features/library/library_screen.dart';
import 'package:sonara/features/player/player_providers.dart';
import 'package:sonara/features/player/player_screen.dart';

import '../player/fake_playback_controller.dart';
import 'fake_music_library_repository.dart';

void main() {
  testWidgets('tapping a track plays it and opens the player', (tester) async {
    final controller = FakePlaybackController();
    final repository = FakeMusicLibraryRepository(
      tracks: const <Track>[
        Track(id: '1', title: 'Song One', uri: '/music/song1.mp3'),
      ],
    );
    final router = GoRouter(
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

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          musicLibraryRepositoryProvider.overrideWithValue(repository),
          playbackControllerProvider.overrideWithValue(controller),
        ],
        child: MaterialApp.router(routerConfig: router),
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
}
