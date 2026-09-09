import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/catalog/library_grouping.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/library/album_detail_screen.dart';
import 'package:linthra/features/library/artist_detail_screen.dart';
import 'package:linthra/features/library/library_screen.dart';
import 'package:linthra/features/library/widgets/track_tile.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';

import '../player/fake_playback_controller.dart';
import 'fake_music_library_repository.dart';

final List<Track> _tracks = <Track>[
  for (int i = 0; i < 4; i++)
    Track(
      id: '$i',
      title: 'Song $i',
      uri: 'jellyfin:$i',
      artistName: 'Daft Punk',
      albumName: i.isEven ? 'Discovery' : 'Homework',
      trackNumber: i + 1,
    ),
];

GoRouter _router(String initialLocation) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: <RouteBase>[
      GoRoute(
        path: AppRoutes.library,
        builder: (_, __) => const LibraryScreen(),
      ),
      GoRoute(
        path: '/library/album/:id',
        builder: (_, GoRouterState s) =>
            AlbumDetailScreen(albumId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/library/artist/:id',
        builder: (_, GoRouterState s) =>
            ArtistDetailScreen(artistId: s.pathParameters['id']!),
      ),
      GoRoute(path: AppRoutes.player, builder: (_, __) => const PlayerScreen()),
    ],
  );
}

Future<void> _pumpLibrary(
  WidgetTester tester,
  Size size, {
  TextScaler textScaler = TextScaler.noScaling,
  String initialLocation = AppRoutes.library,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider.overrideWithValue(
          FakeMusicLibraryRepository(tracks: _tracks),
        ),
        playlistStoreProvider.overrideWithValue(InMemoryPlaylistStore()),
        playbackControllerProvider.overrideWithValue(FakePlaybackController()),
      ],
      child: MaterialApp.router(
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
        routerConfig: _router(initialLocation),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Opens the detail *screen*, which is what these tests are about — on its own
/// route, the way Folders, search and a narrow window all reach it. A wide
/// Library window opens the same screen as a pane beside the grid instead; that
/// path has its own tests in `library_detail_pane_test.dart`.
Future<void> _openAlbum(
  WidgetTester tester,
  Size size, {
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  await _pumpLibrary(
    tester,
    size,
    textScaler: textScaler,
    initialLocation: '/library/album/${albumIdForTrack(_tracks.first)}',
  );
}

Future<void> _openArtist(
  WidgetTester tester,
  Size size, {
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  await _pumpLibrary(
    tester,
    size,
    textScaler: textScaler,
    initialLocation: '/library/artist/${artistIdForTrack(_tracks.first)}',
  );
}

Rect _headerRect(WidgetTester tester, String playLabel) =>
    tester.getRect(find.widgetWithText(FilledButton, playLabel));

Rect _firstTrackRect(WidgetTester tester) =>
    tester.getRect(find.byType(TrackTile).first);

void main() {
  group('AlbumDetailScreen layout', () {
    testWidgets('a phone keeps the header above the tracks', (tester) async {
      await _openAlbum(tester, const Size(390, 844));

      final Rect header = _headerRect(tester, 'Play');
      final Rect track = _firstTrackRect(tester);
      expect(header.bottom, lessThanOrEqualTo(track.top));
      expect(header.left, lessThan(track.right));
    });

    testWidgets('a desktop window puts the album beside its tracks',
        (tester) async {
      await _openAlbum(tester, const Size(1280, 800));

      final Rect header = _headerRect(tester, 'Play');
      final Rect track = _firstTrackRect(tester);
      expect(header.right, lessThanOrEqualTo(track.left));
      expect(track.width, greaterThan(header.width));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the album pane stays put while the tracks scroll',
        (tester) async {
      await _openAlbum(tester, const Size(1280, 800));

      final Rect before = _headerRect(tester, 'Play');
      await tester.drag(find.byType(TrackTile).first, const Offset(0, -200));
      await tester.pumpAndSettle();

      expect(_headerRect(tester, 'Play'), before);
    });

    testWidgets('Play still queues the album from the desktop pane',
        (tester) async {
      await _openAlbum(tester, const Size(1280, 800));

      await tester.tap(find.widgetWithText(FilledButton, 'Play'));
      await tester.pumpAndSettle();

      expect(find.byType(PlayerScreen), findsOneWidget);
    });

    testWidgets('selecting tracks drops back to the single column',
        (tester) async {
      await _openAlbum(tester, const Size(1280, 800));

      await tester.longPress(find.text('Song 0'));
      await tester.pumpAndSettle();

      expect(find.text('1 selected'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Play'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('resizing across the breakpoint keeps the album on screen',
        (tester) async {
      await _openAlbum(tester, const Size(390, 844));

      for (final Size size in <Size>[
        const Size(800, 720),
        const Size(1280, 720),
        const Size(1920, 1080),
        const Size(2560, 1440),
        const Size(390, 844),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'at $size');
        expect(find.text('Song 0'), findsOneWidget, reason: 'at $size');
        expect(
          _headerRect(tester, 'Play').right,
          lessThanOrEqualTo(size.width),
          reason: 'at $size',
        );
      }
    });
  });

  group('ArtistDetailScreen layout', () {
    testWidgets('a phone keeps the header above the catalog', (tester) async {
      await _openArtist(tester, const Size(390, 844));

      expect(
        _headerRect(tester, 'Play all').bottom,
        lessThanOrEqualTo(_firstTrackRect(tester).top),
      );
    });

    testWidgets('a desktop window puts the artist beside their catalog',
        (tester) async {
      await _openArtist(tester, const Size(1280, 800));

      final Rect header = _headerRect(tester, 'Play all');
      expect(header.right, lessThanOrEqualTo(_firstTrackRect(tester).left));
      expect(find.text('Discovery'), findsOneWidget);
      expect(find.text('Homework'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('desktop artist actions stack safely at 2x text scale',
        (tester) async {
      await _openArtist(
        tester,
        const Size(1280, 600),
        textScaler: const TextScaler.linear(2.0),
      );

      final Rect play = _headerRect(tester, 'Play all');
      final Rect shuffle =
          tester.getRect(find.widgetWithText(FilledButton, 'Shuffle all'));
      expect(play.bottom, lessThanOrEqualTo(shuffle.top));
      expect(tester.takeException(), isNull);
    });

    testWidgets('selecting songs drops back to the single column',
        (tester) async {
      await _openArtist(tester, const Size(1280, 800));

      await tester.longPress(find.text('Song 0'));
      await tester.pumpAndSettle();

      expect(find.text('1 selected'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Play all'), findsNothing);
    });

    testWidgets('resizing across the breakpoint keeps the artist on screen',
        (tester) async {
      await _openArtist(tester, const Size(1920, 1080));

      for (final Size size in <Size>[
        const Size(2560, 1440),
        const Size(800, 720),
        const Size(390, 844),
        const Size(1280, 720),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'at $size');
        expect(find.text('Song 0'), findsOneWidget, reason: 'at $size');
      }
    });
  });
}
