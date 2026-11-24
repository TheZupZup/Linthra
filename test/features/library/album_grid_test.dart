import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/library/album_detail_screen.dart';
import 'package:linthra/features/library/library_screen.dart';
import 'package:linthra/features/library/widgets/album_grid.dart';
import 'package:linthra/features/library/widgets/album_grid_card.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/widgets/album_artwork.dart';

import '../player/fake_playback_controller.dart';
import 'fake_music_library_repository.dart';

const List<Track> _tracks = <Track>[
  Track(
    id: '1',
    title: 'Alpha',
    uri: 'jellyfin:1',
    artistName: 'Daft Punk',
    albumName: 'Discovery',
  ),
  Track(
    id: '2',
    title: 'Beta',
    uri: 'jellyfin:2',
    artistName: 'Daft Punk',
    albumName: 'Discovery',
  ),
  Track(
    id: '3',
    title: 'Gamma',
    uri: 'jellyfin:3',
    artistName: 'Adele',
    albumName: '25',
  ),
];

List<Track> _manyAlbums() => <Track>[
      for (int i = 0; i < 6; i++)
        Track(
          id: 'many-$i',
          title: 'Song $i',
          uri: 'jellyfin:many-$i',
          artistName: 'Artist $i',
          albumName: 'Album $i',
        ),
    ];

GoRouter _router() {
  return GoRouter(
    initialLocation: AppRoutes.library,
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
    ],
  );
}

Future<void> _pumpAlbums(
  WidgetTester tester, {
  List<Track>? tracks,
  Size size = const Size(390, 844),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider.overrideWithValue(
          FakeMusicLibraryRepository(tracks: tracks ?? _tracks),
        ),
        playlistStoreProvider.overrideWithValue(InMemoryPlaylistStore()),
        playbackControllerProvider.overrideWithValue(FakePlaybackController()),
      ],
      child: MaterialApp.router(routerConfig: _router()),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Albums'));
  await tester.pumpAndSettle();
}

List<Rect> _cardRects(WidgetTester tester) {
  return tester.elementList(find.byType(AlbumGridCard)).map((Element e) {
    final RenderBox box = e.renderObject! as RenderBox;
    return box.localToGlobal(Offset.zero) & box.size;
  }).toList();
}

List<Rect> _firstRow(WidgetTester tester) {
  final List<Rect> rects = _cardRects(tester);
  final double top = rects
      .map((Rect r) => r.top)
      .reduce((double a, double b) => a < b ? a : b);
  return <Rect>[
    for (final Rect r in rects)
      if (r.top == top) r,
  ]..sort((Rect a, Rect b) => a.left.compareTo(b.left));
}

void main() {
  group('albumGridColumnCount', () {
    test('a phone-width content box gets exactly two columns', () {
      expect(albumGridColumnCount(328), 2);
      expect(albumGridColumnCount(358), 2);
      expect(albumGridColumnCount(398), 2);
    });

    test('a third column waits for its cards and both gutters', () {
      expect(albumGridColumnCount(600), 2);
      expect(albumGridColumnCount(631), 2);
      expect(albumGridColumnCount(632), 3);
      expect(albumGridColumnCount(800), 3);
      expect(albumGridColumnCount(848), 4);
    });

    test('desktop widths add columns instead of inflating covers', () {
      expect(albumGridColumnCount(1168), 5); // 1280x720
      expect(albumGridColumnCount(1808), 7); // 1920x1080
      expect(albumGridColumnCount(2448), 9); // 2560x1440
      expect(albumGridColumnCount(3120), 12); // ultrawide
    });

    test('common 4K width grows beyond the old twelve-column cap', () {
      expect(albumGridColumnCount(3700), 14);
      expect(albumGridColumnCount(3700), greaterThan(12));
    });

    test('desktop cards honor the declared 200-260 width band', () {
      const double gutter = 16;
      for (final double width in <double>[
        632,
        848,
        1168,
        1808,
        2448,
        3120,
        3700,
      ]) {
        final int columns = albumGridColumnCount(width);
        final double cardWidth = (width - gutter * (columns - 1)) / columns;
        expect(
          cardWidth,
          greaterThanOrEqualTo(200),
          reason: 'minimum at $width with $columns columns',
        );
        expect(
          cardWidth,
          lessThanOrEqualTo(260),
          reason: 'maximum at $width with $columns columns',
        );
      }
    });

    test('a degenerate width still renders two columns', () {
      expect(albumGridColumnCount(0), 2);
      expect(albumGridColumnCount(-10), 2);
      expect(albumGridColumnCount(double.infinity), 2);
    });
  });

  group('Albums grid', () {
    testWidgets('albums render as grid cards, not list rows', (tester) async {
      await _pumpAlbums(tester);

      expect(find.byKey(const Key('library_album_grid')), findsOneWidget);
      expect(find.byType(GridView), findsOneWidget);
      expect(find.byType(AlbumGridCard), findsNWidgets(2));
      expect(find.text('Discovery'), findsOneWidget);
      expect(find.text('25'), findsOneWidget);
      expect(find.text('Daft Punk'), findsOneWidget);
      expect(find.text('Adele'), findsOneWidget);
    });

    testWidgets('two cards fit side by side on a typical phone width',
        (tester) async {
      await _pumpAlbums(tester, tracks: _manyAlbums());

      final List<Rect> row = _firstRow(tester);
      expect(row.length, 2);
      expect(row.first.left, lessThan(row.last.left));
      expect(row.last.right, lessThanOrEqualTo(390));
      expect(row.first.width, greaterThan(120));
    });

    testWidgets('artwork stays square', (tester) async {
      await _pumpAlbums(tester);

      final Rect art = tester.getRect(
        find
            .descendant(
              of: find.byType(AlbumGridCard),
              matching: find.byType(AlbumArtwork),
            )
            .first,
      );
      expect(art.width, closeTo(art.height, 0.5));
    });

    testWidgets('a wide window gets more columns than a phone', (tester) async {
      await _pumpAlbums(
        tester,
        tracks: _manyAlbums(),
        size: const Size(1280, 900),
      );

      expect(_firstRow(tester).length, greaterThan(2));
    });

    testWidgets('a desktop window keeps covers card-sized, not inflated',
        (tester) async {
      await _pumpAlbums(
        tester,
        tracks: _manyAlbums(),
        size: const Size(1920, 1080),
      );

      final List<Rect> row = _firstRow(tester);
      expect(row.length, 6);
      for (final Rect card in row) {
        expect(card.width, lessThan(300));
        expect(card.width, greaterThan(180));
      }
      expect(row.last.right, lessThanOrEqualTo(1920));
      expect(tester.takeException(), isNull);
    });

    testWidgets('resizing from phone to desktop reflows without overflow',
        (tester) async {
      await _pumpAlbums(tester, tracks: _manyAlbums());
      expect(_firstRow(tester).length, 2);

      for (final Size size in <Size>[
        const Size(800, 720),
        const Size(1280, 720),
        const Size(2560, 1440),
        const Size(3440, 1440),
        const Size(3840, 2160),
        const Size(390, 844),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'at $size');
        final List<Rect> row = _firstRow(tester);
        expect(
          row.last.right,
          lessThanOrEqualTo(size.width),
          reason: 'at $size',
        );
      }
    });

    testWidgets('tapping a card opens that album', (tester) async {
      await _pumpAlbums(tester);

      await tester.tap(find.text('Discovery'));
      await tester.pumpAndSettle();

      expect(find.text('Play'), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('Gamma'), findsNothing);
    });

    testWidgets('tapping the other card opens the other album', (tester) async {
      await _pumpAlbums(tester);

      await tester.tap(find.text('25'));
      await tester.pumpAndSettle();

      expect(find.text('Gamma'), findsOneWidget);
      expect(find.text('Alpha'), findsNothing);
    });

    testWidgets(
        'long-pressing a card still offers the whole album to a playlist',
        (tester) async {
      await _pumpAlbums(tester);

      await tester.longPress(find.text('Discovery'));
      await tester.pumpAndSettle();

      expect(find.text('Add 2 songs to playlist'), findsOneWidget);
      expect(find.text('New playlist'), findsOneWidget);
    });

    testWidgets('search still filters the grid', (tester) async {
      await _pumpAlbums(tester);

      await tester.enterText(
        find.byKey(const Key('library_search_field')),
        'adele',
      );
      await tester.pumpAndSettle();
      // A search opens on All; the albums chip shows the tab's own results.
      await tester.tap(find.byKey(const Key('library_search_chip_albums')));
      await tester.pumpAndSettle();

      expect(find.byType(AlbumGridCard), findsOneWidget);
      expect(find.text('25'), findsOneWidget);
      expect(find.text('Discovery'), findsNothing);
    });

    testWidgets('a query with no matches still shows the empty state',
        (tester) async {
      await _pumpAlbums(tester);

      await tester.enterText(
        find.byKey(const Key('library_search_field')),
        'zzzzz',
      );
      await tester.pumpAndSettle();

      expect(find.text('No results found.'), findsOneWidget);
      expect(find.byType(AlbumGridCard), findsNothing);
    });

    testWidgets('a long title and artist are clipped, never overflowing',
        (tester) async {
      await _pumpAlbums(
        tester,
        tracks: const <Track>[
          Track(
            id: 'long',
            title: 'Song',
            uri: 'jellyfin:long',
            artistName: 'An Extremely Long Recording Artist Name That Will Not '
                'Fit On One Line Of A Grid Card',
            albumName: 'An Extraordinarily Long Album Title That Runs Well '
                'Past Two Lines Of Any Reasonable Grid Card',
          ),
        ],
      );

      expect(tester.takeException(), isNull);

      final Finder card = find.byType(AlbumGridCard);
      final Text title = tester.widget<Text>(
        find.descendant(of: card, matching: find.textContaining('Album Title')),
      );
      expect(title.maxLines, 2);
      expect(title.overflow, TextOverflow.ellipsis);

      final Text artist = tester.widget<Text>(
        find.descendant(of: card, matching: find.textContaining('Artist Name')),
      );
      expect(artist.maxLines, 1);
      expect(artist.overflow, TextOverflow.ellipsis);
      expect(tester.getRect(card).bottom, lessThanOrEqualTo(844));
    });

    testWidgets('scaled-up text does not overflow a card', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            musicLibraryRepositoryProvider.overrideWithValue(
              FakeMusicLibraryRepository(tracks: _tracks),
            ),
            playlistStoreProvider.overrideWithValue(InMemoryPlaylistStore()),
            playbackControllerProvider
                .overrideWithValue(FakePlaybackController()),
          ],
          child: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
            child: MaterialApp.router(routerConfig: _router()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Albums'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(AlbumGridCard), findsNWidgets(2));
    });

    testWidgets('albums without artwork render the placeholder safely',
        (tester) async {
      await _pumpAlbums(tester);

      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: find.byType(AlbumGridCard),
          matching: find.byIcon(Icons.music_note),
        ),
        findsNWidgets(2),
      );
    });

    testWidgets('a card reads as one item to a screen reader', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pumpAlbums(tester);

      expect(
        find.bySemanticsLabel(RegExp(r'Discovery\s*\n?\s*Daft Punk')),
        findsOneWidget,
      );
      handle.dispose();
    });
  });
}
