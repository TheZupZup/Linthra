import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/appearance/appearance_settings_screen.dart';
import '../features/audiobooks/audiobooks_screen.dart';
import '../features/downloads/downloads_screen.dart';
import '../features/favorites/favorites_screen.dart';
import '../features/library/album_detail_screen.dart';
import '../features/library/artist_detail_screen.dart';
import '../features/library/folders_screen.dart';
import '../features/library/library_screen.dart';
import '../features/onboarding/onboarding_controller.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/player/player_screen.dart';
import '../features/playlists/playlist_detail_screen.dart';
import '../features/playlists/playlists_screen.dart';
import '../features/settings/bug_report/bug_report_screen.dart';
import '../features/settings/hub/about_screen.dart';
import '../features/settings/hub/cache_and_data_screen.dart';
import '../features/settings/hub/connections_settings_screen.dart';
import '../features/settings/hub/diagnostics_support_screen.dart';
import '../features/settings/hub/music_and_playback_screen.dart';
import '../features/settings/hub/offline_downloads_screen.dart';
import '../features/settings/settings_panes.dart';
import '../features/settings/settings_screen.dart';
import '../features/shell/home_shell.dart';
import '../features/smart_mixes/smart_mix_detail_screen.dart';
import '../features/smart_mixes/smart_mixes_screen.dart';
import '../features/support/support_screen.dart';
import 'routes.dart';

/// The root navigator's key.
///
/// Owned by a provider rather than created inside [appRouterProvider] so that
/// app-level chrome sitting *above* the router — the keyboard shortcuts, which
/// have to reach routes pushed over the shell — can address the same navigator
/// the router builds on.
final rootNavigatorKeyProvider = Provider<GlobalKey<NavigatorState>>((ref) {
  return GlobalKey<NavigatorState>(debugLabel: 'root');
});

/// Single source of truth for navigation. Exposed through Riverpod so future
/// guards (e.g. multi-user) can depend on app state.
final appRouterProvider = Provider<GoRouter>((ref) {
  final GlobalKey<NavigatorState> rootNavigatorKey =
      ref.watch(rootNavigatorKeyProvider);
  final List<GlobalKey<NavigatorState>> branchNavigatorKeys =
      <GlobalKey<NavigatorState>>[
    GlobalKey<NavigatorState>(debugLabel: 'libraryBranch'),
    GlobalKey<NavigatorState>(debugLabel: 'foldersBranch'),
    GlobalKey<NavigatorState>(debugLabel: 'playlistsBranch'),
    GlobalKey<NavigatorState>(debugLabel: 'downloadsBranch'),
    GlobalKey<NavigatorState>(debugLabel: 'settingsBranch'),
  ];
  // The Settings pages' own navigator, inside the Settings tab's, so a wide
  // window can show them beside the categories (#753).
  final GlobalKey<NavigatorState> settingsPagesNavigatorKey =
      GlobalKey<NavigatorState>(debugLabel: 'settingsPages');
  final bool onboardingCompleted = ref.read(onboardingControllerProvider);

  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation:
        onboardingCompleted ? AppRoutes.library : AppRoutes.onboarding,
    routes: [
      // First-run onboarding intentionally sits outside the persistent shell.
      // Bootstrap resolves before this router is requested, so startup never
      // paints the wrong destination and then redirects.
      GoRoute(
        path: AppRoutes.onboarding,
        builder: (context, state) => OnboardingScreen(
          replay: state.uri.queryParameters['replay'] == '1',
        ),
      ),
      // Persistent bottom-nav shell with an independent navigation stack per
      // tab, so switching tabs preserves scroll position and history.
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) => HomeShell(
          navigationShell: navigationShell,
          rootNavigatorKey: rootNavigatorKey,
          branchNavigatorKeys: branchNavigatorKeys,
        ),
        branches: [
          StatefulShellBranch(
            navigatorKey: branchNavigatorKeys[0],
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
            navigatorKey: branchNavigatorKeys[1],
            routes: [
              GoRoute(
                path: AppRoutes.folders,
                builder: (context, state) => const FoldersScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: branchNavigatorKeys[2],
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
                  GoRoute(
                    path: 'smart',
                    builder: (context, state) => const SmartMixesScreen(),
                    routes: [
                      GoRoute(
                        path: ':kind',
                        builder: (context, state) => SmartMixDetailScreen(
                          kindId: state.pathParameters['kind']!,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: branchNavigatorKeys[3],
            routes: [
              GoRoute(
                path: AppRoutes.downloads,
                builder: (context, state) => const DownloadsScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: branchNavigatorKeys[4],
            routes: [
              ShellRoute(
                navigatorKey: settingsPagesNavigatorKey,
                builder: (context, state, child) => SettingsPanes(
                  navigatorKey: settingsPagesNavigatorKey,
                  child: child,
                ),
                routes: [
                  GoRoute(
                    path: AppRoutes.settings,
                    builder: (context, state) => const SettingsScreen(),
                    routes: [
                      GoRoute(
                        path: 'connections',
                        builder: (context, state) =>
                            const ConnectionsSettingsScreen(),
                      ),
                      GoRoute(
                        path: 'audiobooks',
                        builder: (context, state) => const AudiobooksScreen(),
                      ),
                      GoRoute(
                        path: 'playback',
                        builder: (context, state) =>
                            const MusicAndPlaybackScreen(),
                      ),
                      GoRoute(
                        path: 'cache',
                        builder: (context, state) => const CacheAndDataScreen(),
                      ),
                      GoRoute(
                        path: 'downloads',
                        builder: (context, state) =>
                            const OfflineDownloadsScreen(),
                      ),
                      GoRoute(
                        path: 'appearance',
                        builder: (context, state) =>
                            const AppearanceSettingsScreen(),
                      ),
                      GoRoute(
                        path: 'diagnostics',
                        builder: (context, state) =>
                            const DiagnosticsSupportScreen(),
                      ),
                      GoRoute(
                        path: 'about',
                        builder: (context, state) => const AboutScreen(),
                      ),
                      GoRoute(
                        path: 'support',
                        builder: (context, state) => const SupportScreen(),
                      ),
                      GoRoute(
                        path: 'report-bug',
                        builder: (context, state) => const BugReportScreen(),
                      ),
                    ],
                  ),
                ],
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
