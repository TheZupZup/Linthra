import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/playlists/playlist_detail_screen.dart';
import 'package:linthra/features/playlists/playlist_drag.dart';

import '../library/fake_music_library_repository.dart';
import '../player/fake_playback_controller.dart';

const List<Track> _catalog = <Track>[
  Track(id: 'a', title: 'Song A', uri: 'file:///a.mp3'),
  Track(id: 'b', title: 'Song B', uri: 'file:///b.mp3'),
  Track(id: 'j', title: 'Server Song', uri: 'jellyfin:1'),
];

/// The open playlist beside a draggable strip standing in for the library.
Future<void> _pump(
  WidgetTester tester,
  InMemoryPlaylistStore store,
  List<Track> dragged,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playlistStoreProvider.overrideWithValue(store),
        musicLibraryRepositoryProvider
            .overrideWithValue(FakeMusicLibraryRepository(tracks: _catalog)),
        playbackControllerProvider.overrideWithValue(FakePlaybackController()),
      ],
      child: MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        home: Row(
          children: <Widget>[
            const Expanded(child: PlaylistDetailScreen(playlistId: 'p1')),
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

Future<void> _dropOnPage(WidgetTester tester) async {
  final TestGesture gesture =
      await tester.startGesture(tester.getCenter(find.text('source row')));
  await gesture.moveBy(const Offset(-40, 0));
  await tester.pump();
  await gesture.moveTo(tester.getCenter(find.byType(PlaylistDropRegion)));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  group('dropping tracks on the open playlist (#389)', () {
    testWidgets('an empty playlist takes the drop', (tester) async {
      // The case that matters most: the page is nothing but an empty state,
      // and it is exactly the playlist somebody wants to drag songs into.
      final InMemoryPlaylistStore store = InMemoryPlaylistStore();
      await store.save(<Playlist>[
        const Playlist(id: 'p1', name: 'Road Trip'),
      ]);
      await _pump(tester, store, <Track>[_catalog[0]]);
      expect(find.text('No songs yet'), findsOneWidget);

      await _dropOnPage(tester);

      final List<Playlist> saved = await store.load();
      expect(saved.single.trackIds, <String>['file:///a.mp3']);
      expect(find.text('Added to Road Trip.'), findsOneWidget);
    });

    testWidgets('a playlist with songs appends to it', (tester) async {
      final InMemoryPlaylistStore store = InMemoryPlaylistStore();
      await store.save(<Playlist>[
        const Playlist(
          id: 'p1',
          name: 'Road Trip',
          trackIds: <String>['file:///a.mp3'],
        ),
      ]);
      await _pump(tester, store, <Track>[_catalog[1]]);

      await _dropOnPage(tester);

      final List<Playlist> saved = await store.load();
      expect(saved.single.trackIds, <String>['file:///a.mp3', 'file:///b.mp3']);
    });

    testWidgets('a synced playlist refuses another source, and says why',
        (tester) async {
      final InMemoryPlaylistStore store = InMemoryPlaylistStore();
      await store.save(<Playlist>[
        const Playlist(
          id: 'p1',
          name: 'Server Mix',
          source: PlaylistSource.jellyfin,
        ),
      ]);
      await _pump(tester, store, <Track>[_catalog[0]]);

      await _dropOnPage(tester);

      final List<Playlist> saved = await store.load();
      expect(saved.single.trackIds, isEmpty);
      expect(
        find.text('Only Jellyfin tracks can be added to Server Mix.'),
        findsOneWidget,
      );
    });

    testWidgets('a duplicate drop leaves the playlist alone', (tester) async {
      final InMemoryPlaylistStore store = InMemoryPlaylistStore();
      await store.save(<Playlist>[
        const Playlist(
          id: 'p1',
          name: 'Road Trip',
          trackIds: <String>['file:///a.mp3'],
        ),
      ]);
      await _pump(tester, store, <Track>[_catalog[0]]);

      await _dropOnPage(tester);

      final List<Playlist> saved = await store.load();
      expect(saved.single.trackIds, <String>['file:///a.mp3']);
      expect(find.text("That song's already in Road Trip."), findsOneWidget);
    });
  });
}
