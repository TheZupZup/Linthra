import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/brand_theme.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/app/theme.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/library/library_screen.dart';
import 'package:linthra/features/library/widgets/album_grid.dart';
import 'package:linthra/features/library/widgets/album_grid_card.dart';
import 'package:linthra/features/library/widgets/artist_grid.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';
import 'package:linthra/shared/focus/focus_ring.dart';

import '../player/fake_playback_controller.dart';
import 'fake_music_library_repository.dart';

/// Browsing the library without a mouse (#390).
///
/// The rules pinned here are the ones a desktop user brings with them: the
/// arrow keys walk a list of songs and a grid of covers, Home and End are its
/// two ends, Enter and Space open what is focused, and whatever is focused says
/// so loudly enough to find, including on an album card, where Material's own
/// ink highlight is painted underneath the cover and cannot be seen at all.
///
/// None of it is gated on Linux, and the last test says why that is safe: on a
/// touch build the same widgets behave exactly as they did before.

final List<Track> _songs = <Track>[
  for (int i = 0; i < 40; i++)
    Track(
      id: 'song-$i',
      title: 'Song ${i.toString().padLeft(2, '0')}',
      uri: 'jellyfin:song-$i',
      albumName: 'Album ${i ~/ 4}',
      artistName: 'Artist ${i ~/ 8}',
    ),
];

final List<Album> _albums = <Album>[
  for (int i = 0; i < 24; i++)
    Album(
      id: 'album-$i',
      title: 'Album ${i.toString().padLeft(2, '0')}',
      artistName: 'Artist $i',
      trackCount: 4,
    ),
];

final List<Artist> _artists = <Artist>[
  for (int i = 0; i < 12; i++)
    Artist(
      id: 'artist-$i',
      name: 'Artist ${i.toString().padLeft(2, '0')}',
      albumCount: 2,
      trackCount: 8,
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
        path: AppRoutes.player,
        builder: (_, __) => const PlayerScreen(),
      ),
    ],
  );
}

Future<FakePlaybackController> _pumpLibrary(
  WidgetTester tester, {
  Size size = const Size(1280, 900),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  final FakePlaybackController controller = FakePlaybackController();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider
            .overrideWithValue(FakeMusicLibraryRepository(tracks: _songs)),
        playbackControllerProvider.overrideWithValue(controller),
      ],
      child: MaterialApp.router(
        theme: AppTheme.dark(BrandPalettes.classic),
        routerConfig: _router(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _pumpAlbums(
  WidgetTester tester, {
  void Function(Album album)? onOpen,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 900);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: AppTheme.dark(BrandPalettes.classic),
        home: Scaffold(
          body: AlbumGrid(albums: _albums, onOpen: onOpen ?? (_) {}),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The label of whatever holds the keyboard, or null when it carries no text.
String? _focusedLabel() {
  final BuildContext? context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return null;
  final Finder text = find.descendant(
    of: find.byWidget(context.widget),
    matching: find.byType(Text),
  );
  if (text.evaluate().isEmpty) return null;
  return (text.evaluate().first.widget as Text).data;
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  // One frame for the move (and any scroll it caused), one for the rows that
  // scroll built.
  await tester.pump();
  await tester.pump();
}

/// How many columns the grid chose, so a test never re-derives the breakpoint
/// arithmetic the grid already owns.
int _albumColumns(WidgetTester tester) {
  final GridView grid = tester.widget<GridView>(
    find.byKey(const Key('library_album_grid')),
  );
  return (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
      .crossAxisCount;
}

/// The label of album [index], as the grid draws it.
String _album(int index) => 'Album ${index.toString().padLeft(2, '0')}';

/// Whether a focus ring is drawn anywhere on screen.
bool _ringVisible(WidgetTester tester) =>
    find.byKey(focusRingKey).evaluate().isNotEmpty;

/// Whether the focus ring is drawn around the row or card carrying [label].
bool _ringAround(WidgetTester tester, String label) {
  final Finder surface = find.ancestor(
    of: find.text(label),
    matching: find.byType(FocusRing),
  );
  if (surface.evaluate().isEmpty) return false;
  return find
      .descendant(of: surface.first, matching: find.byKey(focusRingKey))
      .evaluate()
      .isNotEmpty;
}

void main() {
  group('the songs list', () {
    testWidgets('the arrow keys walk it row by row', (tester) async {
      await _pumpLibrary(tester);
      Focus.of(tester.element(find.text('Song 00'))).requestFocus();
      await tester.pump();

      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusedLabel(), 'Song 01');
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusedLabel(), 'Song 02');
      await _press(tester, LogicalKeyboardKey.arrowUp);
      expect(_focusedLabel(), 'Song 01');
    });

    testWidgets('End and Home reach both ends of the library', (tester) async {
      await _pumpLibrary(tester);
      Focus.of(tester.element(find.text('Song 00'))).requestFocus();
      await tester.pump();
      expect(find.text('Song 39'), findsNothing);

      await _press(tester, LogicalKeyboardKey.end);
      expect(_focusedLabel(), 'Song 39');

      await _press(tester, LogicalKeyboardKey.home);
      expect(_focusedLabel(), 'Song 00');
    });

    testWidgets('the focused row is ringed, and only that row', (tester) async {
      await _pumpLibrary(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      Focus.of(tester.element(find.text('Song 01'))).requestFocus();
      await tester.pump();

      expect(_ringAround(tester, 'Song 01'), isTrue);
      expect(_ringAround(tester, 'Song 02'), isFalse);
    });

    testWidgets('Enter plays the focused row', (tester) async {
      final FakePlaybackController controller = await _pumpLibrary(tester);
      Focus.of(tester.element(find.text('Song 03'))).requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(controller.playedTracks.single.title, 'Song 03');
      expect(find.text('Now Playing'), findsOneWidget);
    });

    testWidgets('Space plays it too', (tester) async {
      final FakePlaybackController controller = await _pumpLibrary(tester);
      Focus.of(tester.element(find.text('Song 05'))).requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();

      expect(controller.playedTracks.single.title, 'Song 05');
    });
  });

  group('the albums grid', () {
    testWidgets('the arrow keys move across and down the grid', (tester) async {
      await _pumpAlbums(tester);
      Focus.of(tester.element(find.text('Album 00'))).requestFocus();
      await tester.pump();

      await _press(tester, LogicalKeyboardKey.arrowRight);
      expect(_focusedLabel(), 'Album 01');

      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusedLabel(), _album(1 + _albumColumns(tester)));
    });

    testWidgets('→ carries on into the next row at a row break',
        (tester) async {
      await _pumpAlbums(tester);
      final int columns = _albumColumns(tester);
      final String lastOfRow = _album(columns - 1);
      final String firstOfNext = _album(columns);
      Focus.of(tester.element(find.text(lastOfRow))).requestFocus();
      await tester.pump();

      await _press(tester, LogicalKeyboardKey.arrowRight);

      expect(_focusedLabel(), firstOfNext);
    });

    testWidgets('the ring is drawn over the cover, not behind it',
        (tester) async {
      await _pumpAlbums(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      expect(_ringVisible(tester), isTrue);
      // Over the whole card, the cover included, rather than only the label
      // strip Material's ink can reach.
      final Finder ring = find.ancestor(
        of: find.text('Album 00'),
        matching: find.byType(FocusRing),
      );
      final Finder card = find.ancestor(
        of: find.text('Album 00'),
        matching: find.byType(AlbumGridCard),
      );
      expect(
        tester.getRect(ring.first).height,
        closeTo(tester.getRect(card.first).height, 1),
      );
    });

    testWidgets('Enter opens the focused album', (tester) async {
      Album? opened;
      await _pumpAlbums(tester, onOpen: (Album album) => opened = album);
      Focus.of(tester.element(find.text('Album 02'))).requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(opened?.title, 'Album 02');
    });
  });

  group('the artists grid', () {
    testWidgets('a single column does not wrap on →', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(500, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.dark(BrandPalettes.classic),
            home: Scaffold(
              body: ArtistGrid(artists: _artists, onOpen: (_) {}),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Focus.of(tester.element(find.text('Artist 00'))).requestFocus();
      await tester.pump();

      await _press(tester, LogicalKeyboardKey.arrowRight);

      // One column is a list, and in a list → is not "the next artist".
      expect(_focusedLabel(), 'Artist 00');
    });
  });

  testWidgets('a touch build behaves exactly as before', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final FakePlaybackController controller = await _pumpLibrary(
        tester,
        size: const Size(420, 900),
      );
      // Touch keeps the focus manager out of keyboard mode, so no ring is
      // painted anywhere, so the phone looks exactly as it did.
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTouch;
      await tester.pump();

      await tester.tap(find.text('Song 01'));
      await tester.pumpAndSettle();

      expect(controller.playedTracks.single.title, 'Song 01');
      expect(_ringVisible(tester), isFalse);
    } finally {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic;
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
