import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/downloads/downloads_screen.dart';
import '../features/favorites/favorites_screen.dart';
import '../features/library/album_detail_screen.dart';
import '../features/library/artist_detail_screen.dart';
import '../features/library/library_screen.dart';
import '../features/player/player_screen.dart';
import '../features/playlists/playlist_detail_screen.dart';
import '../features/playlists/playlists_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/shell/home_shell.dart';
import 'routes.dart';

/// Single source of truth for navigation. Exposed through Riverpod so future
/// guards (e.g. "onboarding complete?", multi-user) can depend on app state.
final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: AppRoutes.library,
    routes: [
      // Persistent bottom-nav shell with an independent navigation stack per
      // tab, so switching tabs preserves scroll position and history.
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            HomeShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.library,
                builder: (context, state) => const LibraryScreen(),
                routes: [
                  GoRoute(
                    path: 'album/:id',
                    builder: (context, state) => AlbumDetailScreen(
                      albumId: state.pathParameters['id']!,
                    ),
                  ),
                  GoRoute(
                    path: 'artist/:id',
                    builder: (context, state) => ArtistDetailScreen(
                      artistId: state.pathParameters['id']!,
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.playlists,
                builder: (context, state) => const PlaylistsScreen(),
                routes: [
                  GoRoute(
                    path: 'favorites',
                    builder: (context, state) => const FavoritesScreen(),
                  ),
                  GoRoute(
                    path: 'detail/:id',
                    builder: (context, state) => PlaylistDetailScreen(
                      playlistId: state.pathParameters['id']!,
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.downloads,
                builder: (context, state) => const DownloadsScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.settings,
                builder: (context, state) => const SettingsScreen(),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: AppRoutes.player,
        builder: (context, state) => const PlayerScreen(),
      ),
    ],
  );
});
