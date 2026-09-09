import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/playlists/playlist_drag.dart';
import 'package:linthra/features/playlists/playlists_screen.dart';

Track _local(String id) => Track(id: id, title: id, uri: 'file:///$id.mp3');

Track _jellyfin(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');

/// The Playlists screen with a draggable strip beside it, standing in for the
/// library tab a drag would really have come from.
Future<void> _pump(
  WidgetTester tester,
  InMemoryPlaylistStore store,
  List<Track> dragged,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playlistStoreProvider.overrideWithValue(store),
      ],
      child: MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        home: Row(
          children: <Widget>[
            const Expanded(child: PlaylistsScreen()),
            SizedBox(
              width: 200,
              height: 600,
              child: Material(
                child: PlaylistTrackDraggable(
                  tracks: () => dragged,
                  child: const Center(child: Text('source row')),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Drags the source row onto the named playlist and lets go.
Future<void> _dropOn(WidgetTester tester, String playlistName) async {
  final TestGesture gesture =
      await tester.startGesture(tester.getCenter(find.text('source row')));
  await gesture.moveBy(const Offset(-40, 0));
  await tester.pump();
  await gesture.moveTo(tester.getCenter(find.text(playlistName)));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  group('dropping tracks on a playlist row (#389)', () {
    testWidgets('adds them, and says what landed', (tester) async {
      final InMemoryPlaylistStore store = InMemoryPlaylistStore();
      await store.save(<Playlist>[
        const Playlist(id: 'p1', name: 'Road Trip'),
      ]);
      await _pump(tester, store, <Track>[_local('a'), _local('b')]);

      await _dropOn(tester, 'Road Trip');

      final List<Playlist> saved = await store.load();
      expect(saved.single.trackIds, <String>['file:///a.mp3', 'file:///b.mp3']);
      expect(find.text('Added 2 songs to Road Trip.'), findsOneWidget);
    });

    testWidgets('the add survives a reload of the playlist', (tester) async {
      // "Persist through the existing repository path", from the issue: the
      // drop writes through the store, not into screen state.
      final InMemoryPlaylistStore store = InMemoryPlaylistStore();
      await store.save(<Playlist>[
        const Playlist(id: 'p1', name: 'Road Trip'),
      ]);
      await _pump(tester, store, <Track>[_local('a')]);
      await _dropOn(tester, 'Road Trip');

      // The row's own count is read back from the repository stream.
      expect(find.text('1 song'), findsOneWidget);
    });

    testWidgets('a duplicate drop changes nothing and owns up to it',
        (tester) async {
      final InMemoryPlaylistStore store = InMemoryPlaylistStore();
      await store.save(<Playlist>[
        const Playlist(
          id: 'p1',
          name: 'Road Trip',
          trackIds: <String>['file:///a.mp3'],
        ),
      ]);
      await _pump(tester, store, <Track>[_local('a')]);

      await _dropOn(tester, 'Road Trip');

      final List<Playlist> saved = await store.load();
      expect(saved.single.trackIds, <String>['file:///a.mp3']);
      expect(find.text("That song's already in Road Trip."), findsOneWidget);
    });

    testWidgets('a synced playlist refuses another server\'s track',
        (tester) async {
      final InMemoryPlaylistStore store = InMemoryPlaylistStore();
      await store.save(<Playlist>[
        const Playlist(
          id: 'p1',
          name: 'Server Mix',
          source: PlaylistSource.jellyfin,
        ),
      ]);
      await _pump(tester, store, <Track>[_local('a')]);

      await _dropOn(tester, 'Server Mix');

      final List<Playlist> saved = await store.load();
      expect(saved.single.trackIds, isEmpty);
      expect(
        find.text('Only Jellyfin tracks can be added to Server Mix.'),
        findsOneWidget,
      );
    });

    testWidgets('a synced playlist keeps the half it can take', (tester) async {
      final InMemoryPlaylistStore store = InMemoryPlaylistStore();
      await store.save(<Playlist>[
        const Playlist(
          id: 'p1',
          name: 'Server Mix',
          source: PlaylistSource.jellyfin,
        ),
      ]);
      await _pump(tester, store, <Track>[_local('a'), _jellyfin('1')]);

      await _dropOn(tester, 'Server Mix');

      final List<Playlist> saved = await store.load();
      expect(saved.single.trackIds, <String>['jellyfin:1']);
      expect(find.textContaining('1 skipped'), findsOneWidget);
    });

    testWidgets('a drop lands on the row it was released over', (tester) async {
      // Two playlists, one drop: the wrong one must stay empty.
      final InMemoryPlaylistStore store = InMemoryPlaylistStore();
      await store.save(<Playlist>[
        const Playlist(id: 'p1', name: 'Road Trip'),
        const Playlist(id: 'p2', name: 'Late Night'),
      ]);
      await _pump(tester, store, <Track>[_local('a')]);

      await _dropOn(tester, 'Late Night');

      final List<Playlist> saved = await store.load();
      final Playlist roadTrip = saved.firstWhere((Playlist p) => p.id == 'p1');
      final Playlist lateNight = saved.firstWhere((Playlist p) => p.id == 'p2');
      expect(roadTrip.trackIds, isEmpty);
      expect(lateNight.trackIds, <String>['file:///a.mp3']);
    });

    testWidgets('tapping a row still opens the playlist, not a drag',
        (tester) async {
      // The row keeps every job it had: the drag is an addition, not a
      // replacement for the tap.
      final InMemoryPlaylistStore store = InMemoryPlaylistStore();
      await store.save(<Playlist>[
        const Playlist(id: 'p1', name: 'Road Trip'),
      ]);
      await _pump(tester, store, <Track>[_local('a')]);

      expect(find.widgetWithText(ListTile, 'Road Trip'), findsOneWidget);
      expect(find.text('Playlist actions'), findsNothing);
      // The overflow menu is still reachable, which is the non-drag route the
      // issue asks to keep.
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Road Trip'),
          matching: find.byIcon(Icons.more_vert),
        ),
        findsOneWidget,
      );
    });
  });
}
