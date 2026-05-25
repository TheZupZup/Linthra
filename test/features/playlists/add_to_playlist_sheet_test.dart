import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/playlists/widgets/add_to_playlist_sheet.dart';

/// Pumps a host with a button that opens the "Add to playlist" sheet for
/// [tracks], backed by a local-only repository seeded from [store].
Future<void> _pump(
  WidgetTester tester,
  InMemoryPlaylistStore store,
  List<Track> tracks,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playlistStoreProvider.overrideWithValue(store),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAddToPlaylistSheet(context, tracks),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Track _track(String id) => Track(id: id, title: id, uri: 'file:///$id.mp3');

void main() {
  group('Add to playlist sheet', () {
    testWidgets('reports only the genuinely-added count, not duplicates',
        (tester) async {
      final store = InMemoryPlaylistStore();
      // 'a' is already in the playlist; only 'b' is genuinely new.
      await store.save(<Playlist>[
        const Playlist(id: 'p1', name: 'My Mix', trackIds: <String>['a']),
      ]);
      await _pump(tester, store, <Track>[_track('a'), _track('b')]);

      await tester.tap(find.text('My Mix'));
      await tester.pumpAndSettle();

      // One was new, one was already there — not "Added 2 songs".
      expect(find.textContaining('Added to My Mix'), findsOneWidget);
      expect(find.textContaining('1 skipped'), findsOneWidget);
      expect(find.textContaining('Added 2 songs'), findsNothing);
    });

    testWidgets('says nothing was added when every track is already present',
        (tester) async {
      final store = InMemoryPlaylistStore();
      await store.save(<Playlist>[
        const Playlist(
          id: 'p1',
          name: 'My Mix',
          trackIds: <String>['a', 'b'],
        ),
      ]);
      await _pump(tester, store, <Track>[_track('a'), _track('b')]);

      await tester.tap(find.text('My Mix'));
      await tester.pumpAndSettle();

      expect(find.textContaining('already in My Mix'), findsOneWidget);
      expect(find.textContaining('Added'), findsNothing);
    });

    testWidgets('reports the real count when adding all-new tracks',
        (tester) async {
      final store = InMemoryPlaylistStore();
      await store.save(<Playlist>[
        const Playlist(id: 'p1', name: 'My Mix'),
      ]);
      await _pump(tester, store, <Track>[_track('a'), _track('b')]);

      await tester.tap(find.text('My Mix'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Added 2 songs to My Mix'), findsOneWidget);
      expect(find.textContaining('skipped'), findsNothing);
    });
  });
}
