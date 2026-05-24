import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/favorites_store.dart';
import 'package:linthra/data/repositories/favorites_repository_provider.dart';
import 'package:linthra/data/repositories/in_memory_favorites_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/favorites/favorites_screen.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';

import '../library/fake_music_library_repository.dart';
import '../player/fake_playback_controller.dart';

GoRouter _router() {
  return GoRouter(
    initialLocation: AppRoutes.favorites,
    routes: [
      GoRoute(
        path: AppRoutes.favorites,
        builder: (_, __) => const FavoritesScreen(),
      ),
      GoRoute(
        path: AppRoutes.player,
        builder: (_, __) => const PlayerScreen(),
      ),
    ],
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required List<Track> tracks,
  required FavoritesData favorites,
  FakePlaybackController? playback,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        musicLibraryRepositoryProvider
            .overrideWithValue(FakeMusicLibraryRepository(tracks: tracks)),
        favoritesStoreProvider
            .overrideWithValue(InMemoryFavoritesStore(favorites)),
        if (playback != null)
          playbackControllerProvider.overrideWithValue(playback),
      ],
      child: MaterialApp.router(routerConfig: _router()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('FavoritesScreen', () {
    testWidgets('lists only favourited tracks, local and Jellyfin', (
      tester,
    ) async {
      await _pump(
        tester,
        tracks: const <Track>[
          Track(id: 'local1', title: 'Alpha', uri: 'file:///a.mp3'),
          Track(id: 'remote1', title: 'Bravo', uri: 'jellyfin:remote1'),
          Track(id: 'other', title: 'Charlie', uri: 'file:///c.mp3'),
        ],
        favorites: const FavoritesData(
          localIds: {'local1'},
          remoteIds: {'remote1'},
        ),
      );

      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Bravo'), findsOneWidget);
      // A non-favourited track from the catalog is not shown.
      expect(find.text('Charlie'), findsNothing);
    });

    testWidgets('shows an empty state when nothing is favourited', (
      tester,
    ) async {
      await _pump(
        tester,
        tracks: const <Track>[
          Track(id: 'local1', title: 'Alpha', uri: 'file:///a.mp3'),
        ],
        favorites: FavoritesData.empty,
      );

      expect(find.text('No favorites yet'), findsOneWidget);
      expect(find.text('Alpha'), findsNothing);
    });

    testWidgets('tapping a favourite plays it and queues the rest', (
      tester,
    ) async {
      final controller = FakePlaybackController();
      await _pump(
        tester,
        tracks: const <Track>[
          Track(id: 'a', title: 'Alpha', uri: 'file:///a.mp3'),
          Track(id: 'b', title: 'Bravo', uri: 'file:///b.mp3'),
          Track(id: 'c', title: 'Charlie', uri: 'file:///c.mp3'),
        ],
        favorites: const FavoritesData(localIds: {'a', 'b', 'c'}),
        playback: controller,
      );

      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();

      // The tapped track plays and the rest of the list (sorted by title)
      // follows it in the up-next queue.
      expect(controller.state.currentTrack?.id, 'a');
      expect(
        controller.state.upNext.map((t) => t.id).toList(),
        ['b', 'c'],
      );
    });
  });
}
