import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_session_store.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/jellyfin_session_store_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/playlists/playlists_screen.dart';

Future<void> _pump(
  WidgetTester tester,
  InMemoryPlaylistStore store, {
  JellyfinSession? session,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playlistStoreProvider.overrideWithValue(store),
        // Drives the Jellyfin connection state the empty-state copy keys off; a
        // null session keeps the screen "not signed in".
        jellyfinSessionStoreProvider.overrideWithValue(
          InMemoryJellyfinSessionStore(initialSession: session),
        ),
      ],
      child: const MaterialApp(home: PlaylistsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('PlaylistsScreen', () {
    testWidgets('renders the empty state when there are no playlists',
        (tester) async {
      await _pump(tester, InMemoryPlaylistStore());
      expect(find.text('No playlists yet'), findsOneWidget);
      // Favorites is always pinned at the top.
      expect(find.text('Favorites'), findsOneWidget);
      // The create affordance is present.
      expect(find.widgetWithText(FloatingActionButton, 'New playlist'),
          findsOneWidget);
    });

    testWidgets('pins the Smart mixes section', (tester) async {
      await _pump(tester, InMemoryPlaylistStore());
      expect(find.text('Smart mixes'), findsOneWidget);
      expect(find.text('Made by Linthra'), findsOneWidget);
    });

    testWidgets('lists existing playlists with a song count', (tester) async {
      final InMemoryPlaylistStore store = InMemoryPlaylistStore();
      await store.save(<Playlist>[
        const Playlist(
          id: 'p1',
          name: 'Road Trip',
          trackIds: <String>['a', 'b'],
        ),
      ]);
      await _pump(tester, store);

      expect(find.text('Road Trip'), findsOneWidget);
      expect(find.text('2 songs'), findsOneWidget);
      expect(find.text('No playlists yet'), findsNothing);
    });

    testWidgets('shows a subtle Jellyfin source label on a synced playlist',
        (tester) async {
      final InMemoryPlaylistStore store = InMemoryPlaylistStore();
      await store.save(<Playlist>[
        const Playlist(
          id: 'p1',
          name: 'Server Mix',
          source: PlaylistSource.jellyfin,
          remoteId: 'srv-1',
          trackIds: <String>['a', 'b'],
          syncState: PlaylistSyncState.synced,
        ),
      ]);
      await _pump(tester, store);

      expect(find.text('Server Mix'), findsOneWidget);
      // The origin is shown subtly in the subtitle, not as separate chrome.
      expect(find.text('2 songs · Jellyfin'), findsOneWidget);
    });

    testWidgets('empty state hints at signing in when not connected',
        (tester) async {
      await _pump(tester, InMemoryPlaylistStore());

      expect(find.text('No playlists yet'), findsOneWidget);
      expect(find.textContaining('sign in to Jellyfin'), findsOneWidget);
    });

    testWidgets('empty state mentions sync when connected to Jellyfin',
        (tester) async {
      await _pump(
        tester,
        InMemoryPlaylistStore(),
        session: const JellyfinSession(
          baseUrl: 'https://music.example.com',
          userId: 'u',
          accessToken: 'tok',
          deviceId: 'd',
        ),
      );

      expect(find.text('No playlists yet'), findsOneWidget);
      expect(find.textContaining('after you sync'), findsOneWidget);
    });

    testWidgets('creating a playlist via the dialog adds it to the list',
        (tester) async {
      await _pump(tester, InMemoryPlaylistStore());

      await tester
          .tap(find.widgetWithText(FloatingActionButton, 'New playlist'));
      await tester.pumpAndSettle();

      expect(find.text('New playlist'), findsWidgets);
      await tester.enterText(find.byType(TextField).first, 'Chill');
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();

      expect(find.text('Chill'), findsOneWidget);
    });

    testWidgets('deleting a playlist asks for confirmation with clear labels',
        (tester) async {
      final InMemoryPlaylistStore store = InMemoryPlaylistStore();
      await store.save(<Playlist>[
        const Playlist(id: 'p1', name: 'Road Trip'),
      ]);
      await _pump(tester, store);

      await tester.tap(find.byTooltip('Playlist actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(
          find.textContaining('Delete playlist “Road Trip”?'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Delete'), findsOneWidget);

      // Confirm the delete and the row disappears.
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Road Trip'), findsNothing);
    });
  });

  // The list can rebuild a row while that row's dialog is up: the phone turned
  // sideways to type, a shorter window, a refresh that dropped a playlist. The
  // change the listener confirmed must still be made.
  group('PlaylistsScreen row actions after the row was rebuilt', () {
    Future<InMemoryPlaylistStore> pumpTwelve(WidgetTester tester) async {
      // A phone held upright, with playlists down to the bottom of the screen.
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 915);
      addTearDown(tester.view.reset);
      final InMemoryPlaylistStore store = InMemoryPlaylistStore();
      await store.save(<Playlist>[
        for (int i = 0; i < 12; i++) Playlist(id: 'p$i', name: 'Playlist $i'),
      ]);
      await _pump(tester, store);
      return store;
    }

    Future<void> openRowMenu(WidgetTester tester, String name) async {
      final Finder row =
          find.ancestor(of: find.text(name), matching: find.byType(ListTile));
      await tester.tap(
        find.descendant(of: row, matching: find.byTooltip('Playlist actions')),
      );
      await tester.pumpAndSettle();
    }

    // Landscape leaves room for a few rows only, so the list drops the lower
    // ones, the row whose dialog is open among them.
    Future<void> turnSideways(WidgetTester tester) async {
      tester.view.physicalSize = const Size(915, 412);
      await tester.pumpAndSettle();
    }

    testWidgets('a rename saved after the row was rebuilt is applied',
        (tester) async {
      final InMemoryPlaylistStore store = await pumpTwelve(tester);
      await openRowMenu(tester, 'Playlist 8');
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Road Trip');

      await turnSideways(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final List<Playlist> saved = await store.load();
      expect(saved.firstWhere((Playlist p) => p.id == 'p8').name, 'Road Trip');
    });

    testWidgets('a delete confirmed after the row was rebuilt is applied',
        (tester) async {
      final InMemoryPlaylistStore store = await pumpTwelve(tester);
      await openRowMenu(tester, 'Playlist 8');
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      await turnSideways(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      final List<Playlist> saved = await store.load();
      expect(saved.map((Playlist p) => p.id), isNot(contains('p8')));
    });
  });
}
