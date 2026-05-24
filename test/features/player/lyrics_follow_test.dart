import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/lyrics.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/lyrics_service.dart';
import 'package:linthra/core/services/playback_controller.dart';
import 'package:linthra/features/player/lyrics_providers.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';

import 'fake_playback_controller.dart';

/// A lyrics backend returning canned, per-track lyrics — so a test can prove
/// the lyrics view follows whatever is playing.
class _FakeLyricsService implements LyricsService {
  _FakeLyricsService(this._byTrackId);

  final Map<String, Lyrics?> _byTrackId;

  @override
  Future<Lyrics?> lyricsFor(Track track) async => _byTrackId[track.id];
}

const _trackA = Track(id: 'a', title: 'Song A', uri: 'jellyfin:a');
const _trackB = Track(id: 'b', title: 'Song B', uri: 'jellyfin:b');
const _trackC = Track(id: 'c', title: 'Song C', uri: 'jellyfin:c');

final Map<String, Lyrics?> _lyrics = <String, Lyrics?>{
  'a': const Lyrics(lines: <LyricLine>[LyricLine(text: 'Aaa line')]),
  'b': const Lyrics(lines: <LyricLine>[LyricLine(text: 'Bbb line')]),
  'c': null,
};

PlaybackState _playing(Track track) =>
    PlaybackState(status: PlaybackStatus.playing, currentTrack: track);

Future<void> _pumpPlayer(
  WidgetTester tester, {
  required PlaybackController controller,
  required LyricsService lyrics,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playbackControllerProvider.overrideWithValue(controller),
        lyricsServiceProvider.overrideWithValue(lyrics),
      ],
      child: const MaterialApp(home: PlayerScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openLyrics(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Lyrics'));
  await tester.pumpAndSettle();
}

void main() {
  group('Lyrics follow the playing track', () {
    testWidgets('shows lyrics for the current track', (tester) async {
      await _pumpPlayer(
        tester,
        controller: FakePlaybackController(initial: _playing(_trackA)),
        lyrics: _FakeLyricsService(_lyrics),
      );

      await _openLyrics(tester);

      expect(find.text('Aaa line'), findsOneWidget);
    });

    testWidgets('updates when the current track changes', (tester) async {
      final controller = FakePlaybackController(initial: _playing(_trackA));
      await _pumpPlayer(
        tester,
        controller: controller,
        lyrics: _FakeLyricsService(_lyrics),
      );
      await _openLyrics(tester);
      expect(find.text('Aaa line'), findsOneWidget);

      // Skipping to the next track re-resolves the lyrics in place.
      controller.emit(_playing(_trackB));
      await tester.pumpAndSettle();

      expect(find.text('Bbb line'), findsOneWidget);
      expect(find.text('Aaa line'), findsNothing);
    });

    testWidgets('shows the empty state when the track has no lyrics',
        (tester) async {
      await _pumpPlayer(
        tester,
        controller: FakePlaybackController(initial: _playing(_trackC)),
        lyrics: _FakeLyricsService(_lyrics),
      );

      await _openLyrics(tester);

      expect(find.text('No lyrics available yet.'), findsOneWidget);
    });

    testWidgets('does not show stale lyrics from the previous track',
        (tester) async {
      final controller = FakePlaybackController(initial: _playing(_trackA));
      await _pumpPlayer(
        tester,
        controller: controller,
        lyrics: _FakeLyricsService(_lyrics),
      );
      await _openLyrics(tester);
      expect(find.text('Aaa line'), findsOneWidget);

      // Moving to a track with no lyrics must clear the previous song's lines.
      controller.emit(_playing(_trackC));
      await tester.pumpAndSettle();

      expect(find.text('Aaa line'), findsNothing);
      expect(find.text('No lyrics available yet.'), findsOneWidget);
    });
  });
}
