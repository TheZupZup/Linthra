import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/smart_mixes/smart_mix_detail_screen.dart';
import 'package:linthra/features/smart_mixes/smart_mixes_screen.dart';

import '../library/fake_music_library_repository.dart';
import '../player/fake_playback_controller.dart';

const List<Track> _tracks = <Track>[
  Track(id: 'a', title: 'Song A', uri: 'jellyfin:a'),
  Track(id: 'b', title: 'Song B', uri: 'jellyfin:b'),
  Track(id: 'c', title: 'Song C', uri: 'jellyfin:c'),
];

GoRouter _router() {
  return GoRouter(
    initialLocation: AppRoutes.smartMixes,
    routes: <RouteBase>[
      GoRoute(
        path: AppRoutes.smartMixes,
        builder: (_, __) => const SmartMixesScreen(),
        routes: <RouteBase>[
          GoRoute(
            path: ':kind',
            builder: (_, GoRouterState s) =>
                SmartMixDetailScreen(kindId: s.pathParameters['kind']!),
          ),
        ],
      ),
      GoRoute(
        path: AppRoutes.player,
        builder: (_, __) => const Scaffold(body: Text('player-screen')),
      ),
    ],
  );
}

Future<void> _pump(WidgetTester tester, {List<Track> tracks = _tracks}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider
            .overrideWithValue(FakeMusicLibraryRepository(tracks: tracks)),
        playbackControllerProvider.overrideWithValue(FakePlaybackController()),
      ],
      child: MaterialApp.router(routerConfig: _router()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('SmartMixesScreen', () {
    testWidgets('lists every smart mix', (tester) async {
      await _pump(tester);

      expect(find.text('Recently added'), findsOneWidget);
      expect(find.text('Recently played'), findsOneWidget);
      expect(find.text('Most played'), findsOneWidget);
      expect(find.text('Favorites'), findsOneWidget);
      expect(find.text('Downloaded'), findsOneWidget);
      expect(find.text('Random mix'), findsOneWidget);
      expect(find.text('Never played'), findsOneWidget);
    });

    testWidgets('shows a live track count per mix', (tester) async {
      await _pump(tester);

      // Catalog-wide mixes count all 3 tracks; signal-based mixes are empty
      // until the user plays / likes / downloads something.
      expect(find.text('New in your library · 3 songs'), findsOneWidget);
      expect(find.text('A fresh shuffle every time · 3 songs'), findsOneWidget);
      expect(find.text('Jump back in · 0 songs'), findsOneWidget);
    });

    testWidgets('tapping a mix opens its tracks', (tester) async {
      await _pump(tester);

      await tester.tap(find.text('Recently added'));
      await tester.pumpAndSettle();

      // The detail screen's Play action plus the tracks confirm we navigated.
      expect(find.text('Play'), findsOneWidget);
      expect(find.text('Shuffle'), findsOneWidget);
      expect(find.text('Song A'), findsOneWidget);
      expect(find.text('Song B'), findsOneWidget);
      expect(find.text('Song C'), findsOneWidget);
    });
  });
}
