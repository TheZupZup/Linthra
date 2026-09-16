import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/core/models/music_folder.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/folder_browsable_music_source.dart';
import 'package:linthra/features/library/folder_browser_providers.dart';
import 'package:linthra/features/library/folders_screen.dart';
import 'package:linthra/features/player/player_providers.dart';

import '../player/fake_playback_controller.dart';

/// Folders is a top-level destination rather than a Library tab, so it has to
/// stand on its own: it carries its own app bar, it explains itself when no
/// folder-capable server is connected instead of looking broken, and it still
/// walks the hierarchy one level at a time.
class _FakeFolderSource implements FolderBrowsableMusicSource {
  _FakeFolderSource({
    required this.id,
    required this.displayName,
    required this.roots,
    this.children = const <String, MusicFolderListing>{},
  });

  @override
  final String id;

  @override
  final String displayName;

  final List<MusicFolder> roots;
  final Map<String, MusicFolderListing> children;

  /// How many times each folder id was actually asked of the "server", so a
  /// test can tell a cache hit from a round trip.
  final Map<String, int> folderFetches = <String, int>{};

  /// How many times the root list was asked of the "server".
  int rootFetches = 0;

  @override
  Future<List<MusicFolder>> fetchRootFolders() async {
    rootFetches++;
    return roots;
  }

  /// When true, the next fetchFolder throws, standing in for a server that
  /// dropped mid-refresh.
  bool failNextFolderFetch = false;

  @override
  Future<MusicFolderListing> fetchFolder(String folderId) async {
    folderFetches[folderId] = (folderFetches[folderId] ?? 0) + 1;
    if (failNextFolderFetch) {
      failNextFolderFetch = false;
      throw StateError('server unavailable');
    }
    return children[folderId] ?? MusicFolderListing.empty;
  }
}

/// The screen registers a [BackButtonListener] while it is inside a folder, so
/// it has to be hosted under a Router the way the app's shell hosts it.
GoRouter _router() {
  return GoRouter(
    routes: <RouteBase>[
      GoRoute(path: '/', builder: (_, __) => const FoldersScreen()),
    ],
  );
}

Future<void> _pump(
  WidgetTester tester, {
  List<FolderBrowsableMusicSource> sources =
      const <FolderBrowsableMusicSource>[],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        folderBrowsableSourcesProvider.overrideWithValue(sources),
        playbackControllerProvider.overrideWithValue(FakePlaybackController()),
      ],
      child: MaterialApp.router(routerConfig: _router()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('FoldersScreen', () {
    testWidgets('with nothing connected it says so and names its own bar',
        (tester) async {
      await _pump(tester);

      expect(find.widgetWithText(AppBar, 'Folders'), findsOneWidget);
      expect(find.text('No music folders yet'), findsOneWidget);
      expect(
        find.textContaining('Jellyfin or Navidrome'),
        findsOneWidget,
      );
      // With nothing to browse, the one thing worth doing from here is adding
      // a folder of your own (see folders_add_folder_test.dart).
      expect(
        find.byKey(const Key('folders_empty_add_folder')),
        findsOneWidget,
      );
    });

    testWidgets('lists a connected source\'s roots under its name',
        (tester) async {
      await _pump(
        tester,
        sources: <FolderBrowsableMusicSource>[
          _FakeFolderSource(
            id: 'subsonic',
            displayName: 'Navidrome',
            roots: const <MusicFolder>[MusicFolder(id: 'r1', name: 'Music')],
          ),
        ],
      );

      expect(find.text('Navidrome'), findsOneWidget);
      expect(find.text('Music'), findsOneWidget);
    });

    testWidgets('opening a folder walks into it and Back walks out again',
        (tester) async {
      await _pump(
        tester,
        sources: <FolderBrowsableMusicSource>[
          _FakeFolderSource(
            id: 'subsonic',
            displayName: 'Navidrome',
            roots: const <MusicFolder>[MusicFolder(id: 'r1', name: 'Music')],
            children: const <String, MusicFolderListing>{
              'r1': MusicFolderListing(
                folders: <MusicFolder>[
                  MusicFolder(id: 'c1', name: 'Live Sets')
                ],
                tracks: <Track>[
                  Track(id: 't1', title: 'Opener', uri: 'subsonic:t1'),
                ],
              ),
            },
          ),
        ],
      );

      await tester.tap(find.text('Music'));
      await tester.pumpAndSettle();

      // One level down: the child folder and the tracks beside it, with the
      // trail's own header naming where we are and which server it came from.
      expect(find.text('Live Sets'), findsOneWidget);
      expect(find.text('Opener'), findsOneWidget);
      expect(find.byKey(const Key('folder_browser_header')), findsOneWidget);

      await tester.tap(find.byTooltip('Back to previous folder'));
      await tester.pumpAndSettle();

      expect(find.text('Music'), findsOneWidget);
      expect(find.byKey(const Key('folder_browser_header')), findsNothing);
    });

    testWidgets('walking back up does not re-ask the server (#581)',
        (tester) async {
      final _FakeFolderSource source = _FakeFolderSource(
        id: 'subsonic',
        displayName: 'Navidrome',
        roots: const <MusicFolder>[MusicFolder(id: 'r1', name: 'Music')],
        children: const <String, MusicFolderListing>{
          'r1': MusicFolderListing(
            folders: <MusicFolder>[MusicFolder(id: 'c1', name: 'Live Sets')],
          ),
        },
      );
      await _pump(tester, sources: <FolderBrowsableMusicSource>[source]);

      await tester.tap(find.text('Music'));
      await tester.pumpAndSettle();
      expect(source.folderFetches['r1'], 1);

      await tester.tap(find.byTooltip('Back to previous folder'));
      await tester.pumpAndSettle();

      // Coming back to a level that was on screen a moment ago used to re-fetch
      // it, which is what made going up feel slow on a remote library.
      await tester.tap(find.text('Music'));
      await tester.pumpAndSettle();

      expect(find.text('Live Sets'), findsOneWidget);
      expect(source.folderFetches['r1'], 1);
    });

    testWidgets('pull to refresh re-reads the folder (#581)', (tester) async {
      final _FakeFolderSource source = _FakeFolderSource(
        id: 'subsonic',
        displayName: 'Navidrome',
        roots: const <MusicFolder>[MusicFolder(id: 'r1', name: 'Music')],
        children: const <String, MusicFolderListing>{
          'r1': MusicFolderListing(
            folders: <MusicFolder>[MusicFolder(id: 'c1', name: 'Live Sets')],
          ),
        },
      );
      await _pump(tester, sources: <FolderBrowsableMusicSource>[source]);

      await tester.tap(find.text('Music'));
      await tester.pumpAndSettle();
      expect(source.folderFetches['r1'], 1);

      // The deliberate way past the cache, for a folder changed on the server.
      await tester.fling(
        find.byKey(const Key('folder_browser_contents')),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();

      expect(source.folderFetches['r1'], 2);
    });

    testWidgets(
        'the cache window starts when the level is left, not when it '
        'was fetched (#581)', (tester) async {
      final _FakeFolderSource source = _FakeFolderSource(
        id: 'subsonic',
        displayName: 'Navidrome',
        roots: const <MusicFolder>[MusicFolder(id: 'r1', name: 'Music')],
        children: const <String, MusicFolderListing>{
          'r1': MusicFolderListing(
            folders: <MusicFolder>[MusicFolder(id: 'c1', name: 'Live Sets')],
          ),
          'c1': MusicFolderListing(
            tracks: <Track>[Track(id: 't1', title: 'Opener', uri: 'sub:t1')],
          ),
        },
      );
      await _pump(tester, sources: <FolderBrowsableMusicSource>[source]);

      await tester.tap(find.text('Music'));
      await tester.pumpAndSettle();
      expect(source.folderFetches['r1'], 1);

      // Reading a long track list for longer than the cache window. Measuring
      // the window from the fetch would expire it right here, while the folder
      // is still on screen.
      await tester.pump(folderListingCacheDuration * 2);

      await tester.tap(find.text('Live Sets'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Back to previous folder'));
      await tester.pumpAndSettle();

      expect(find.text('Live Sets'), findsOneWidget);
      expect(source.folderFetches['r1'], 1);
    });

    testWidgets('an empty folder can still be pulled to refresh (#581)',
        (tester) async {
      final _FakeFolderSource source = _FakeFolderSource(
        id: 'subsonic',
        displayName: 'Navidrome',
        roots: const <MusicFolder>[MusicFolder(id: 'r1', name: 'Music')],
        // No children and no tracks: nothing to overscroll against, which is
        // exactly the folder someone refreshes after filling it server-side.
        children: const <String, MusicFolderListing>{},
      );
      await _pump(tester, sources: <FolderBrowsableMusicSource>[source]);

      await tester.tap(find.text('Music'));
      await tester.pumpAndSettle();
      expect(find.text('This folder is empty'), findsOneWidget);
      expect(source.folderFetches['r1'], 1);

      await tester.fling(
        find.byKey(const Key('folder_browser_contents')),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();

      expect(source.folderFetches['r1'], 2);
    });

    testWidgets('a refresh that fails shows the error, not a crash (#581)',
        (tester) async {
      final _FakeFolderSource source = _FakeFolderSource(
        id: 'subsonic',
        displayName: 'Navidrome',
        roots: const <MusicFolder>[MusicFolder(id: 'r1', name: 'Music')],
        children: const <String, MusicFolderListing>{
          'r1': MusicFolderListing(
            folders: <MusicFolder>[MusicFolder(id: 'c1', name: 'Live Sets')],
          ),
        },
      );
      await _pump(tester, sources: <FolderBrowsableMusicSource>[source]);

      await tester.tap(find.text('Music'));
      await tester.pumpAndSettle();

      source.failNextFolderFetch = true;
      await tester.fling(
        find.byKey(const Key('folder_browser_contents')),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();

      // The provider's error state is what the user sees. The gesture's future
      // must not also surface the same failure as an unhandled async error,
      // which the test binding would report as a failure.
      expect(find.text('Could not open this folder.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the root list can be pulled to refresh too (#581)',
        (tester) async {
      final _FakeFolderSource source = _FakeFolderSource(
        id: 'subsonic',
        displayName: 'Navidrome',
        roots: const <MusicFolder>[MusicFolder(id: 'r1', name: 'Music')],
      );
      await _pump(tester, sources: <FolderBrowsableMusicSource>[source]);
      expect(source.rootFetches, 1);

      // Roots are cached like any other level, so a top-level folder added on
      // the server needs the same deliberate way past it.
      await tester.fling(
        find.byKey(const Key('folder_browser_roots')),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();

      expect(source.rootFetches, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('signing the source out returns to the roots', (tester) async {
      final _FakeFolderSource source = _FakeFolderSource(
        id: 'subsonic',
        displayName: 'Navidrome',
        roots: const <MusicFolder>[MusicFolder(id: 'r1', name: 'Music')],
        children: const <String, MusicFolderListing>{
          'r1': MusicFolderListing(
            folders: <MusicFolder>[MusicFolder(id: 'c1', name: 'Live Sets')],
          ),
        },
      );
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          folderBrowsableSourcesProvider
              .overrideWith((ref) => ref.watch(_sourcesProvider)),
          playbackControllerProvider
              .overrideWithValue(FakePlaybackController()),
        ],
      );
      addTearDown(container.dispose);
      container.read(_sourcesProvider.notifier).state =
          <FolderBrowsableMusicSource>[source];

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: _router()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Music'));
      await tester.pumpAndSettle();
      expect(find.text('Live Sets'), findsOneWidget);

      // The session goes away while the screen is deep in the trail: it must
      // fall back to the roots rather than keep fetching with a dead session.
      container.read(_sourcesProvider.notifier).state =
          <FolderBrowsableMusicSource>[];
      await tester.pumpAndSettle();

      expect(find.text('No music folders yet'), findsOneWidget);
    });
  });
}

/// Stands in for the connected-sources list so a test can sign a server out
/// mid-flight.
final _sourcesProvider = StateProvider<List<FolderBrowsableMusicSource>>((ref) {
  return const <FolderBrowsableMusicSource>[];
});
