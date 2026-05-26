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
}
