import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/playlists/playlist_detail_screen.dart';
import 'package:linthra/features/playlists/widgets/add_to_playlist_sheet.dart';

import '../library/fake_music_library_repository.dart';
import '../player/fake_playback_controller.dart';

// A playlist change finishes after an await: saving, and for a synced
// playlist the push to the server (up to its 20 s timeout). Anything the
// screen does once it lands has to act on what it opened, not on whatever
// route happens to be on top by then.

/// Holds every save while [gate] is set, the way a slow disk or a server
/// push holds the repository's await.
class _GatedPlaylistStore extends InMemoryPlaylistStore {
  Completer<void>? gate;

  @override
  Future<void> save(List<Playlist> playlists) async {
    final Completer<void>? pending = gate;
    if (pending != null) await pending.future;
    return super.save(playlists);
  }
}

const List<Track> _tracks = <Track>[
  Track(id: 'a', title: 'Song A', uri: 'file:///a.mp3'),
  Track(id: 'b', title: 'Song B', uri: 'file:///b.mp3'),
];

Future<_GatedPlaylistStore> _store() async {
  final _GatedPlaylistStore store = _GatedPlaylistStore();
  await store.save(const <Playlist>[
    Playlist(id: 'p1', name: 'Road Trip', trackIds: <String>['file:///a.mp3']),
  ]);
  return store;
}

void main() {
  group('Add to playlist', () {
    /// An album page, pushed over home, with a button that opens the sheet:
    /// the page a stray pop would close.
    Future<void> openSheetFromAlbumPage(
      WidgetTester tester,
      _GatedPlaylistStore store,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[playlistStoreProvider.overrideWithValue(store)],
          child: MaterialApp(
            home: Builder(
              builder: (BuildContext context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext context) => Scaffold(
                        body: Column(
                          children: <Widget>[
                            const Text('Album page'),
                            TextButton(
                              onPressed: () => showAddToPlaylistSheet(
                                context,
                                const <Track>[
                                  Track(
                                    id: 'b',
                                    title: 'Song B',
                                    uri: 'file:///b.mp3',
                                  ),
                                ],
                              ),
                              child: const Text('open sheet'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  child: const Text('open album'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open album'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open sheet'));
      await tester.pumpAndSettle();
      expect(find.text('Road Trip'), findsOneWidget);
    }

    testWidgets('a second tap while the first add saves leaves the page',
        (WidgetTester tester) async {
      final _GatedPlaylistStore store = await _store();
      await openSheetFromAlbumPage(tester, store);

      store.gate = Completer<void>();
      await tester.tap(find.text('Road Trip'));
      await tester.pump();
      if (find.text('Road Trip').evaluate().isNotEmpty) {
        await tester.tap(find.text('Road Trip'), warnIfMissed: false);
        await tester.pump();
      }
      store.gate!.complete();
      store.gate = null;
      await tester.pumpAndSettle();

      expect(find.text('Album page'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final List<Playlist> saved = await store.load();
      expect(
        saved.single.trackIds,
        <String>['file:///a.mp3', 'file:///b.mp3'],
      );
    });

    testWidgets('dismissing the sheet while the add saves leaves the page',
        (WidgetTester tester) async {
      final _GatedPlaylistStore store = await _store();
      await openSheetFromAlbumPage(tester, store);

      store.gate = Completer<void>();
      await tester.tap(find.text('Road Trip'));
      await tester.pump();
      // Swipe it away, or tap outside it, while the add is still saving.
      if (find.text('Road Trip').evaluate().isNotEmpty) {
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
      }
      store.gate!.complete();
      store.gate = null;
      await tester.pumpAndSettle();

      expect(find.text('Album page'), findsOneWidget);
      expect(find.textContaining('Added to Road Trip'), findsOneWidget);
    });
  });

  group('Playlist detail', () {
    late FakePlaybackController controller;

    setUp(() => controller = FakePlaybackController());

    /// The Playlists tab with the playlist pushed over it.
    Future<void> openDetail(
      WidgetTester tester,
      _GatedPlaylistStore store,
    ) async {
      final GoRouter router = GoRouter(
        initialLocation: '/',
        routes: <RouteBase>[
          GoRoute(
            path: '/',
            builder: (BuildContext context, __) => Scaffold(
              body: Column(
                children: <Widget>[
                  const Text('Playlists tab'),
                  TextButton(
                    onPressed: () => context.push('/p1'),
                    child: const Text('open playlist'),
                  ),
                ],
              ),
            ),
          ),
          GoRoute(
            path: '/p1',
            builder: (_, __) => const PlaylistDetailScreen(playlistId: 'p1'),
          ),
          GoRoute(
            path: AppRoutes.player,
            builder: (_, __) => const Scaffold(body: Text('player-screen')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            playlistStoreProvider.overrideWithValue(store),
            musicLibraryRepositoryProvider
                .overrideWithValue(FakeMusicLibraryRepository(tracks: _tracks)),
            playbackControllerProvider.overrideWithValue(controller),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open playlist'));
      await tester.pumpAndSettle();
      expect(find.text('Road Trip'), findsWidgets);
    }

    testWidgets('Back during a delete still lands on the Playlists tab',
        (WidgetTester tester) async {
      final _GatedPlaylistStore store = await _store();
      await openDetail(tester, store);

      await tester.tap(find.byTooltip('Playlist actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete playlist'));
      await tester.pumpAndSettle();
      store.gate = Completer<void>();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      // The listener goes back while the delete is still saving.
      if (find.text('Playlists tab').evaluate().isEmpty) {
        await tester.pageBack();
        await tester.pumpAndSettle();
      }
      store.gate!.complete();
      store.gate = null;
      await tester.pumpAndSettle();

      expect(find.text('Playlists tab'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(await store.load(), isEmpty);
    });

    testWidgets('leaving during a bulk remove does not touch the closed screen',
        (WidgetTester tester) async {
      final _GatedPlaylistStore store = _GatedPlaylistStore();
      await store.save(const <Playlist>[
        Playlist(
          id: 'p1',
          name: 'Road Trip',
          trackIds: <String>['file:///a.mp3', 'file:///b.mp3'],
        ),
      ]);
      await openDetail(tester, store);

      await tester.longPress(find.text('Song A'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove from playlist'));
      await tester.pumpAndSettle();
      store.gate = Completer<void>();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pump();
      // System back twice: once out of selection, once off the screen.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      if (find.text('Playlists tab').evaluate().isEmpty) {
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
      }
      store.gate!.complete();
      store.gate = null;
      await tester.pumpAndSettle();

      expect(find.text('Playlists tab'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
