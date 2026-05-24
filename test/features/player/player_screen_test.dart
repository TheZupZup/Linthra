import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/playback_controller.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';
import 'package:linthra/features/player/widgets/album_artwork.dart';
import 'package:linthra/features/player/widgets/now_playing_background.dart';

import 'fake_playback_controller.dart';

Future<void> _pumpScreen(
  WidgetTester tester,
  PlaybackController controller,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playbackControllerProvider.overrideWithValue(controller),
      ],
      child: const MaterialApp(home: PlayerScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

/// A local track with full metadata but no artwork, so widget tests never reach
/// for the network (artwork falls back to the placeholder).
const _localTrack = Track(
  id: '1',
  title: 'Song One',
  uri: '/music/song1.mp3',
  artistName: 'Artist A',
  albumName: 'Album B',
);

FakePlaybackController _playing({
  Track track = _localTrack,
  PlaybackSource source = PlaybackSource.localFile,
  List<Track> upNext = const <Track>[],
  bool hasPrevious = false,
  Duration position = Duration.zero,
  Duration duration = Duration.zero,
}) {
  return FakePlaybackController(
    initial: PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: track,
      source: source,
      upNext: upNext,
      hasPrevious: hasPrevious,
      position: position,
      duration: duration,
    ),
  );
}

void main() {
  group('PlayerScreen', () {
    testWidgets('shows the empty state with no track', (tester) async {
      await _pumpScreen(tester, FakePlaybackController());

      expect(find.text('Nothing playing'), findsOneWidget);
    });

    testWidgets('renders the title, artist, and album', (tester) async {
      await _pumpScreen(tester, _playing());

      expect(find.text('Song One'), findsOneWidget);
      expect(find.text('Artist A'), findsOneWidget);
      expect(find.text('Album B'), findsOneWidget);
      // While playing, the toggle offers Pause.
      expect(find.byTooltip('Pause'), findsOneWidget);
    });

    testWidgets('falls back to placeholder artwork', (tester) async {
      await _pumpScreen(tester, _playing());

      // The background and artwork widgets render even without an artwork URI,
      // and no broken-image exception is thrown.
      expect(find.byType(NowPlayingBackground), findsOneWidget);
      expect(find.byType(AlbumArtwork), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows the LOCAL FILE badge', (tester) async {
      await _pumpScreen(tester, _playing(source: PlaybackSource.localFile));

      expect(find.text('LOCAL FILE'), findsOneWidget);
    });

    testWidgets('shows the STREAMING DIRECT badge', (tester) async {
      await _pumpScreen(
        tester,
        _playing(
          track: const Track(id: 't1', title: 'Remote', uri: 'jellyfin:t1'),
          source: PlaybackSource.streamingDirect,
        ),
      );

      expect(find.text('STREAMING DIRECT'), findsOneWidget);
    });

    testWidgets('shows the OFFLINE CACHE badge', (tester) async {
      await _pumpScreen(
        tester,
        _playing(
          track: const Track(id: 't1', title: 'Remote', uri: 'jellyfin:t1'),
          source: PlaybackSource.offlineCache,
        ),
      );

      expect(find.text('OFFLINE CACHE'), findsOneWidget);
    });

    testWidgets('play/pause delegates to the controller', (tester) async {
      final controller = FakePlaybackController(
        initial: const PlaybackState(
          status: PlaybackStatus.paused,
          currentTrack: _localTrack,
          source: PlaybackSource.localFile,
        ),
      );
      await _pumpScreen(tester, controller);

      // Paused: tapping the toggle resumes playback.
      await tester.tap(find.byTooltip('Play'));
      expect(controller.playCount, 1);
    });

    testWidgets('Next delegates to the controller', (tester) async {
      final controller = _playing(
        upNext: const <Track>[Track(id: '2', title: 'Song Two', uri: '/2.mp3')],
      );
      await _pumpScreen(tester, controller);

      await tester.tap(find.byTooltip('Next'));
      expect(controller.skipCount, 1);
    });

    testWidgets('Previous delegates to the controller', (tester) async {
      final controller = _playing(hasPrevious: true);
      await _pumpScreen(tester, controller);

      await tester.tap(find.byTooltip('Previous'));
      expect(controller.previousCount, 1);
    });

    testWidgets('disables Next with an empty queue', (tester) async {
      await _pumpScreen(tester, _playing());

      final next = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.skip_next),
          matching: find.byType(IconButton),
        ),
      );
      expect(next.onPressed, isNull);
    });

    testWidgets('the slider seeks via the controller', (tester) async {
      final controller = _playing(duration: const Duration(minutes: 3));
      await _pumpScreen(tester, controller);

      // Tapping the slider commits a seek to roughly its center.
      await tester.tap(find.byType(Slider));
      await tester.pumpAndSettle();

      expect(controller.seeks, isNotEmpty);
      expect(controller.seeks.first, greaterThan(Duration.zero));
    });

    testWidgets('the queue button opens up-next', (tester) async {
      final controller = _playing(
        upNext: const <Track>[
          Track(id: '2', title: 'Song Two', uri: '/2.mp3'),
          Track(id: '3', title: 'Song Three', uri: '/3.mp3'),
        ],
      );
      await _pumpScreen(tester, controller);

      await tester.tap(find.byTooltip('Queue'));
      await tester.pumpAndSettle();

      expect(find.text('Up next'), findsOneWidget);
      expect(find.text('Song Two'), findsOneWidget);
      expect(find.text('Song Three'), findsOneWidget);

      await tester.tap(find.text('Clear'));
      expect(controller.clearCount, 1);
    });

    testWidgets('shows the specific playback error', (tester) async {
      final controller = FakePlaybackController(
        initial: const PlaybackState(
          status: PlaybackStatus.error,
          currentTrack: Track(
            id: 't1',
            title: 'Remote Song',
            uri: 'jellyfin:t1',
          ),
          errorMessage: 'Your Jellyfin session has expired.',
        ),
      );
      await _pumpScreen(tester, controller);

      expect(find.text('Remote Song'), findsOneWidget);
      expect(find.text('Your Jellyfin session has expired.'), findsOneWidget);
      // The generic fallback is not shown when a specific message exists.
      expect(find.text("Couldn't play this track"), findsNothing);
    });

    testWidgets('shows the Lyrics empty state with no source', (tester) async {
      await _pumpScreen(tester, _playing());

      // The entry point is visible on the player.
      expect(find.byTooltip('Lyrics'), findsOneWidget);

      await tester.tap(find.byTooltip('Lyrics'));
      await tester.pumpAndSettle();

      // The default lyrics backend returns none (local track, no Jellyfin), so
      // it shows a calm placeholder rather than a blank sheet.
      expect(find.text('No lyrics available yet.'), findsOneWidget);
    });

    testWidgets('the favorite button toggles the heart', (tester) async {
      await _pumpScreen(tester, _playing());

      // Starts unfavorited: outline heart, "Favorite" tooltip.
      expect(find.byTooltip('Favorite'), findsOneWidget);
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);

      await tester.tap(find.byTooltip('Favorite'));
      await tester.pumpAndSettle();

      // Now favorited: filled heart, updated tooltip (local-only default store).
      expect(find.byTooltip('Remove from favorites'), findsOneWidget);
      expect(find.byIcon(Icons.favorite), findsOneWidget);
    });

    testWidgets('reacts to state pushed on the stream', (tester) async {
      final controller = FakePlaybackController();
      await _pumpScreen(tester, controller);
      expect(find.text('Nothing playing'), findsOneWidget);

      controller.emit(
        const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: Track(id: '1', title: 'Live Track', uri: '/l.mp3'),
          source: PlaybackSource.localFile,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Live Track'), findsOneWidget);
      expect(find.byTooltip('Pause'), findsOneWidget);
    });

    testWidgets('shuffle button reflects state and toggles it', (tester) async {
      final controller = _playing();
      await _pumpScreen(tester, controller);

      // Off by default.
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.shuffle))
            .isSelected,
        isFalse,
      );

      await tester.tap(find.byIcon(Icons.shuffle));
      await tester.pumpAndSettle();

      // The state flipped and the button now reads as selected.
      expect(controller.state.shuffleEnabled, isTrue);
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.shuffle))
            .isSelected,
        isTrue,
      );
    });

    testWidgets('repeat button cycles off -> all -> one -> off',
        (tester) async {
      final controller = _playing();
      await _pumpScreen(tester, controller);

      // Off: plain repeat glyph, not selected.
      expect(find.byIcon(Icons.repeat), findsOneWidget);
      expect(find.byIcon(Icons.repeat_one), findsNothing);
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.repeat))
            .isSelected,
        isFalse,
      );

      // -> repeat all: still the repeat glyph, now selected.
      await tester.tap(find.byIcon(Icons.repeat));
      await tester.pumpAndSettle();
      expect(controller.state.repeatMode, RepeatMode.all);
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.repeat))
            .isSelected,
        isTrue,
      );

      // -> repeat one: glyph switches to repeat_one.
      await tester.tap(find.byIcon(Icons.repeat));
      await tester.pumpAndSettle();
      expect(controller.state.repeatMode, RepeatMode.one);
      expect(find.byIcon(Icons.repeat_one), findsOneWidget);

      // -> off: back to the plain glyph.
      await tester.tap(find.byIcon(Icons.repeat_one));
      await tester.pumpAndSettle();
      expect(controller.state.repeatMode, RepeatMode.off);
      expect(find.byIcon(Icons.repeat), findsOneWidget);
    });

    testWidgets('renders the cast button in the header', (tester) async {
      await _pumpScreen(tester, _playing());

      // Default cast backend is unavailable, so the (honest) cast glyph shows.
      expect(find.byIcon(Icons.cast), findsOneWidget);
      expect(find.byTooltip('Cast (coming soon)'), findsOneWidget);
    });

    testWidgets('cast button opens an honest unavailable sheet',
        (tester) async {
      await _pumpScreen(tester, _playing());

      await tester.tap(find.byIcon(Icons.cast));
      await tester.pumpAndSettle();

      expect(find.text('Casting isn\'t available yet'), findsOneWidget);
    });
  });
}
