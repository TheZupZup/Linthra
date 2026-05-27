import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/widgets/queue_sheet.dart';

import 'fake_playback_controller.dart';

Track _track(String id) =>
    Track(id: id, title: 'Song $id', uri: '/$id.mp3', artistName: 'Artist $id');

/// Pumps a host with a button that opens the Queue sheet over the given
/// [controller], faithfully exercising it as the modal bottom sheet it is.
Future<void> _open(
  WidgetTester tester,
  FakePlaybackController controller, {
  InMemoryPlaylistStore? store,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playbackControllerProvider.overrideWithValue(controller),
        if (store != null) playlistStoreProvider.overrideWithValue(store),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showQueueSheet(context),
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

void main() {
  group('QueueSheet', () {
    testWidgets('renders the current track and the up-next tracks',
        (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B'), _track('C')]);

      await _open(tester, controller);

      expect(find.text('Now playing'), findsOneWidget);
      expect(find.text('Up next'), findsOneWidget);
      // Current track + both up-next tracks are listed.
      expect(find.text('Song A'), findsOneWidget);
      expect(find.text('Song B'), findsOneWidget);
      expect(find.text('Song C'), findsOneWidget);
    });

    testWidgets('removing an up-next entry keeps the current track playing',
        (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B'), _track('C')]);

      await _open(tester, controller);
      // Remove the first up-next track (Song B).
      await tester.tap(find.byTooltip('Remove from queue').first);
      await tester.pumpAndSettle();

      expect(controller.state.currentTrack, _track('A'));
      expect(controller.state.upNext, [_track('C')]);
      expect(find.text('Song B'), findsNothing);
    });

    testWidgets('Clear empties up next but keeps the current track',
        (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B'), _track('C')]);

      await _open(tester, controller);
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();

      expect(controller.clearCount, 1);
      expect(controller.state.currentTrack, _track('A'));
      expect(controller.state.upNext, isEmpty);
      expect(find.text('Song B'), findsNothing);
    });

    testWidgets('tapping an up-next track plays it now', (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B'), _track('C')]);

      await _open(tester, controller);
      await tester.tap(find.text('Song C'));
      await tester.pumpAndSettle();

      expect(controller.state.currentTrack, _track('C'));
    });

    testWidgets('shows a drag handle for each upcoming track', (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B'), _track('C')]);

      await _open(tester, controller);

      // One handle per up-next track (B and C), not the current one.
      expect(find.byIcon(Icons.drag_handle), findsNWidgets(2));
      expect(find.byType(ReorderableDragStartListener), findsNWidgets(2));
    });

    testWidgets('history is shown and tapping it steps back', (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B'), _track('C')]);
      await controller.skipToNext(); // current B, history [A], up next [C]

      await _open(tester, controller);

      expect(find.text('Previously played'), findsOneWidget);
      expect(find.text('Song A'), findsOneWidget);

      await tester.tap(find.text('Song A'));
      await tester.pumpAndSettle();

      expect(controller.state.currentTrack, _track('A'));
    });

    testWidgets('save queue as playlist creates a local playlist',
        (tester) async {
      final store = InMemoryPlaylistStore();
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B'), _track('C')]);

      await _open(tester, controller, store: store);
      await tester.tap(find.byTooltip('Save queue as playlist'));
      await tester.pumpAndSettle();

      // The shared create-playlist dialog: enter a name, then Create.
      await tester.enterText(find.byType(TextField).first, 'My Queue');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      final List<Playlist> saved = await store.load();
      expect(saved, hasLength(1));
      expect(saved.single.name, 'My Queue');
      // Order is history + current + up-next: [A, B, C].
      expect(saved.single.trackIds, <String>['A', 'B', 'C']);
      expect(saved.single.source, PlaylistSource.local);
      expect(find.textContaining('Saved 3 songs to'), findsOneWidget);
    });

    testWidgets('never renders a track uri / authenticated source string',
        (tester) async {
      final controller = FakePlaybackController();
      // A remote track whose source reference would carry a token if leaked.
      await controller.playTracks(const <Track>[
        Track(
          id: 'r1',
          title: 'Remote One',
          uri: 'https://host/stream?api_key=SECRETTOKEN123',
          artistName: 'Artist R',
        ),
        Track(
          id: 'r2',
          title: 'Remote Two',
          uri: 'jellyfin:r2',
          artistName: 'Artist R',
        ),
      ]);

      await _open(tester, controller);

      // Titles/artists render; the raw uri and any token never do.
      expect(find.text('Remote One'), findsOneWidget);
      expect(find.text('Remote Two'), findsOneWidget);
      expect(find.textContaining('SECRETTOKEN'), findsNothing);
      expect(find.textContaining('api_key'), findsNothing);
      expect(find.textContaining('https://'), findsNothing);
      expect(find.textContaining('jellyfin:'), findsNothing);
    });
  });
}
