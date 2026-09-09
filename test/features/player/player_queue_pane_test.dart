import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/lyrics.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/lyrics_service.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/player/lyrics_providers.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';
import 'package:linthra/features/player/widgets/album_artwork.dart';
import 'package:linthra/features/player/widgets/lyrics_view.dart';
import 'package:linthra/features/player/widgets/queue_sheet.dart';

import 'fake_playback_controller.dart';

/// A window wide enough for a third column shows the queue beside the cover
/// instead of over it — the point of the width being that lyrics and up-next
/// are readable at the same time. Narrower windows keep the sheet, so the queue
/// is reachable at every size, and the pane never squeezes the cover and the
/// transport to make room for itself.
class _FakeLyricsService implements LyricsService {
  _FakeLyricsService(this._lyrics);

  final Lyrics? _lyrics;

  @override
  Future<Lyrics?> lyricsFor(Track track) async => _lyrics;
}

const Track _track = Track(
  id: '1',
  title: 'Song One',
  uri: '/music/song1.mp3',
  artistName: 'Artist A',
  albumName: 'Album B',
);

const Track _next = Track(
  id: '2',
  title: 'Song Two',
  uri: '/music/song2.mp3',
  artistName: 'Artist A',
);

const Lyrics _lyrics = Lyrics(
  lines: <LyricLine>[
    LyricLine(text: 'First line'),
    LyricLine(text: 'Second line'),
  ],
);

/// Just above `_queuePaneMinWidth` (1000 + 340 + 24).
const Size _paneWindow = Size(1400, 900);

/// A desktop window that is wide enough for two columns but not three.
const Size _twoColumnWindow = Size(1280, 800);

Future<void> _pumpPlayer(
  WidgetTester tester, {
  required Size size,
  InMemoryPlaylistStore? store,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playbackControllerProvider.overrideWithValue(
          FakePlaybackController(
            initial: const PlaybackState(
              status: PlaybackStatus.playing,
              currentTrack: _track,
              upNext: <Track>[_next],
            ),
          ),
        ),
        lyricsServiceProvider.overrideWithValue(_FakeLyricsService(_lyrics)),
        if (store != null) playlistStoreProvider.overrideWithValue(store),
      ],
      child: const MaterialApp(home: PlayerScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _resize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  await tester.pumpAndSettle();
}

void main() {
  group('Now Playing queue pane', () {
    testWidgets('a wide window opens the queue beside the cover',
        (tester) async {
      await _pumpPlayer(tester, size: _paneWindow);

      expect(find.byType(QueueSheet), findsNothing);
      await tester.tap(find.byTooltip('Show queue'));
      await tester.pumpAndSettle();

      expect(find.byType(QueueSheet), findsOneWidget);
      // A pane, not a sheet: nothing is covering the rest of the screen.
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        tester.getRect(find.byType(AlbumArtwork).first).right,
        lessThanOrEqualTo(tester.getRect(find.byType(QueueSheet)).left),
      );
      expect(find.text('Song Two'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('lyrics and the queue sit side by side', (tester) async {
      await _pumpPlayer(tester, size: _paneWindow);

      await tester.tap(find.byTooltip('Show queue'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Lyrics'));
      await tester.pumpAndSettle();

      expect(find.byType(LyricsView), findsOneWidget);
      expect(find.byType(QueueSheet), findsOneWidget);
      expect(
        tester.getRect(find.byType(LyricsView)).right,
        lessThanOrEqualTo(tester.getRect(find.byType(QueueSheet)).left),
      );
      // The transport is still where it was, under both of them.
      expect(find.byTooltip('Pause'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the toggle closes it again', (tester) async {
      await _pumpPlayer(tester, size: _paneWindow);

      await tester.tap(find.byTooltip('Show queue'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Hide queue'));
      await tester.pumpAndSettle();

      expect(find.byType(QueueSheet), findsNothing);
      expect(find.byTooltip('Show queue'), findsOneWidget);
    });

    testWidgets('narrowing hides the pane and widening brings it back',
        (tester) async {
      await _pumpPlayer(tester, size: _paneWindow);

      await tester.tap(find.byTooltip('Show queue'));
      await tester.pumpAndSettle();
      expect(find.byType(QueueSheet), findsOneWidget);

      await _resize(tester, _twoColumnWindow);
      expect(find.byType(QueueSheet), findsNothing);
      // Playback is untouched, and the queue is still reachable as a sheet.
      expect(find.byTooltip('Pause'), findsOneWidget);
      expect(find.byTooltip('Queue'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await _resize(tester, _paneWindow);
      expect(find.byType(QueueSheet), findsOneWidget);
    });

    testWidgets('a window without room for a third column keeps the sheet',
        (tester) async {
      await _pumpPlayer(tester, size: _twoColumnWindow);

      expect(find.byTooltip('Show queue'), findsNothing);
      await tester.tap(find.byTooltip('Queue'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(QueueSheet), findsOneWidget);
    });

    testWidgets('a phone keeps the sheet too', (tester) async {
      await _pumpPlayer(tester, size: const Size(390, 844));

      await tester.tap(find.byTooltip('Queue'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    /// As a sheet the queue is a route and outlives its own dialogs. As a pane
    /// it is just a widget in the layout, and narrowing the window takes it off
    /// screen mid-action — with the name prompt still up on top.
    testWidgets('saving survives the pane closing under the dialog',
        (tester) async {
      final InMemoryPlaylistStore store = InMemoryPlaylistStore();
      await _pumpPlayer(tester, size: _paneWindow, store: store);

      await tester.tap(find.byTooltip('Show queue'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Save queue as playlist'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'My Queue');
      await tester.pumpAndSettle();

      // The window narrows while the prompt is open: the pane goes, the dialog
      // stays.
      await _resize(tester, _twoColumnWindow);
      expect(find.byType(QueueSheet), findsNothing);
      expect(find.text('Create'), findsOneWidget);

      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      final List<Playlist> saved = await store.load();
      expect(saved, hasLength(1));
      expect(saved.single.name, 'My Queue');
      expect(saved.single.trackIds, <String>[_track.uri, _next.uri]);
      expect(tester.takeException(), isNull);
    });
  });
}
