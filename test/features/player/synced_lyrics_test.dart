import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/cast_playback_status.dart';
import 'package:linthra/core/models/cast_state.dart';
import 'package:linthra/core/models/lyrics.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/active_playback_controller.dart';
import 'package:linthra/core/services/lyrics_service.dart';
import 'package:linthra/features/player/cast/cast_providers.dart';
import 'package:linthra/features/player/lyrics_providers.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';

import 'cast/fake_cast_service.dart';
import 'fake_playback_controller.dart';

class _FakeLyricsService implements LyricsService {
  _FakeLyricsService(this._byId);
  final Map<String, Lyrics?> _byId;
  @override
  Future<Lyrics?> lyricsFor(Track track) async => _byId[track.id];
}

const _trackA = Track(id: 'a', title: 'Song A', uri: 'jellyfin:a');

const _synced = Lyrics(lines: <LyricLine>[
  LyricLine(text: 'line one', start: Duration.zero),
  LyricLine(text: 'line two', start: Duration(seconds: 10)),
  LyricLine(text: 'line three', start: Duration(seconds: 20)),
]);

const _plain = Lyrics(lines: <LyricLine>[
  LyricLine(text: 'plain one'),
  LyricLine(text: 'plain two'),
]);

PlaybackState _playingAt(Duration position) => PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: _trackA,
      position: position,
      duration: const Duration(seconds: 30),
    );

/// The style of a synced lyric line. Material wraps many things in
/// [AnimatedDefaultTextStyle], so we pick the one that *directly* wraps this
/// line's [Text] (the synced view's own wrapper).
TextStyle _styleOf(WidgetTester tester, String text) {
  final candidates = tester.widgetList<AnimatedDefaultTextStyle>(
    find.ancestor(
      of: find.text(text),
      matching: find.byType(AnimatedDefaultTextStyle),
    ),
  );
  for (final AnimatedDefaultTextStyle w in candidates) {
    final Widget child = w.child;
    if (child is Text && child.data == text) return w.style;
  }
  return candidates.first.style;
}

Future<void> _openLyrics(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Lyrics'));
  await tester.pumpAndSettle();
}

void main() {
  group('synced lyrics highlight + follow position (local)', () {
    Future<void> pump(
      WidgetTester tester, {
      required FakePlaybackController controller,
      required Lyrics lyrics,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playbackControllerProvider.overrideWithValue(controller),
            lyricsServiceProvider.overrideWithValue(
              _FakeLyricsService(<String, Lyrics?>{'a': lyrics}),
            ),
          ],
          child: const MaterialApp(home: PlayerScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('highlights the line active at the current position',
        (tester) async {
      await pump(
        tester,
        controller: FakePlaybackController(
            initial: _playingAt(const Duration(seconds: 12))),
        lyrics: _synced,
      );
      await _openLyrics(tester);

      // 12s lands on "line two" (10s..20s): bold, and a distinct colour from a
      // neighbouring (muted) line.
      expect(_styleOf(tester, 'line two').fontWeight, FontWeight.w700);
      expect(_styleOf(tester, 'line one').fontWeight, FontWeight.w500);
      expect(
        _styleOf(tester, 'line two').color,
        isNot(_styleOf(tester, 'line one').color),
      );
    });

    testWidgets('moves the highlight as the position advances', (tester) async {
      final controller = FakePlaybackController(
          initial: _playingAt(const Duration(seconds: 12)));
      await pump(tester, controller: controller, lyrics: _synced);
      await _openLyrics(tester);
      expect(_styleOf(tester, 'line two').fontWeight, FontWeight.w700);

      // Advance past the third line's start.
      controller.emit(_playingAt(const Duration(seconds: 22)));
      await tester.pumpAndSettle();

      expect(_styleOf(tester, 'line three').fontWeight, FontWeight.w700);
      expect(_styleOf(tester, 'line two').fontWeight, FontWeight.w500);
    });

    testWidgets('plain lyrics render without timed highlighting',
        (tester) async {
      await pump(
        tester,
        controller: FakePlaybackController(initial: _playingAt(Duration.zero)),
        lyrics: _plain,
      );
      await _openLyrics(tester);

      expect(find.text('plain one'), findsOneWidget);
      expect(find.text('plain two'), findsOneWidget);
      // The plain (static) path is used, not the synced highlighting one.
      expect(find.byKey(const Key('plain-lyrics')), findsOneWidget);
      expect(find.byKey(const Key('synced-lyrics')), findsNothing);
    });

    testWidgets('shows the empty state when there are no lyrics',
        (tester) async {
      await pump(
        tester,
        controller: FakePlaybackController(initial: _playingAt(Duration.zero)),
        lyrics: const Lyrics(lines: <LyricLine>[]),
      );
      await _openLyrics(tester);

      expect(find.text('No lyrics available yet.'), findsOneWidget);
    });
  });

  group('synced lyrics follow the cast position', () {
    testWidgets('the highlight follows the receiver position while casting',
        (tester) async {
      final local = FakePlaybackController(
          initial: _playingAt(const Duration(seconds: 1)));
      final cast = FakeCastService(
        initial: const CastState(
          availability: CastAvailability.connected,
          connectedDevice: CastDevice(id: 'd1', name: 'Living Room'),
          isCasting: true,
        ),
      );
      addTearDown(cast.dispose);
      final router = ActivePlaybackController(local: local, cast: cast);
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playbackControllerProvider.overrideWithValue(router),
            castServiceProvider.overrideWithValue(cast),
            lyricsServiceProvider.overrideWithValue(
              _FakeLyricsService(<String, Lyrics?>{'a': _synced}),
            ),
          ],
          child: const MaterialApp(home: PlayerScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // The receiver reports a paused position at 12s → "line two" is active.
      // (Paused so no interpolation ticker runs and the test can settle.)
      cast.emitPlayback(const CastPlaybackStatus(
        status: PlaybackStatus.paused,
        position: Duration(seconds: 12),
        duration: Duration(seconds: 30),
      ));
      await tester.pumpAndSettle();
      await _openLyrics(tester);

      expect(_styleOf(tester, 'line two').fontWeight, FontWeight.w700);

      // The receiver moves on to 22s → the highlight follows to "line three".
      cast.emitPlayback(const CastPlaybackStatus(
        status: PlaybackStatus.paused,
        position: Duration(seconds: 22),
        duration: Duration(seconds: 30),
      ));
      await tester.pumpAndSettle();

      expect(_styleOf(tester, 'line three').fontWeight, FontWeight.w700);
    });
  });
}
