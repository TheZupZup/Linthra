import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/lyrics.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/player/player_providers.dart';

import 'fake_playback_controller.dart';

/// Battery-sensitive contract for the synced lyrics highlight.
///
/// The synced lyrics view selects the *active line index* from the unified
/// playback position (see `_SyncedLyrics._activeLine`), so it rebuilds only when
/// the highlighted line changes — not on every ~4 Hz position tick. These tests
/// exercise that exact selection through a [ProviderContainer], so a regression
/// back to watching the raw position (which would rebuild the whole synced list
/// four times a second for the length of a track) fails here.
const _track = Track(id: 'a', title: 'Song A', uri: 'jellyfin:a');

const _synced = Lyrics(lines: <LyricLine>[
  LyricLine(text: 'line one', start: Duration.zero),
  LyricLine(text: 'line two', start: Duration(seconds: 10)),
  LyricLine(text: 'line three', start: Duration(seconds: 20)),
]);

PlaybackState _playingAt(Duration position) => PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: _track,
      position: position,
      duration: const Duration(seconds: 30),
    );

/// Mirrors `_SyncedLyrics._activeLine`: the active line index, selected from the
/// unified position with a controller fallback before the first stream event.
ProviderListenable<int> _activeLineOf(FakePlaybackController controller) {
  return playbackStateProvider.select(
    (s) => _synced
        .activeLineIndex(s.valueOrNull?.position ?? controller.state.position),
  );
}

void main() {
  group('synced lyrics highlight throttling', () {
    test('sub-line position ticks do not change the highlighted line',
        () async {
      final controller = FakePlaybackController(
          initial: _playingAt(const Duration(seconds: 12)));
      addTearDown(controller.dispose);
      final container = ProviderContainer(overrides: <Override>[
        playbackControllerProvider.overrideWithValue(controller),
      ]);
      addTearDown(container.dispose);

      final List<int> changes = <int>[];
      container.listen<int>(
        _activeLineOf(controller),
        (int? previous, int next) => changes.add(next),
        fireImmediately: true,
      );

      // 12s lands on "line two" (10s..20s) → index 1, the initial highlight.
      expect(changes, <int>[1]);

      // Several position ticks that all stay within line two: the highlight must
      // not change, so the widget never rebuilds across these ticks.
      for (final int ms in <int>[12500, 13000, 15000, 19000, 19999]) {
        controller.emit(
          controller.state.copyWith(position: Duration(milliseconds: ms)),
        );
        await pumpEventQueue();
      }
      expect(
        changes,
        <int>[1],
        reason: 'sub-line position ticks must not retrigger the highlight',
      );

      // Crossing into line three (>=20s) is exactly one change.
      controller.emit(
        controller.state.copyWith(position: const Duration(seconds: 21)),
      );
      await pumpEventQueue();
      expect(changes, <int>[1, 2]);
    });

    test('the highlight still follows every real line boundary', () async {
      final controller =
          FakePlaybackController(initial: _playingAt(Duration.zero));
      addTearDown(controller.dispose);
      final container = ProviderContainer(overrides: <Override>[
        playbackControllerProvider.overrideWithValue(controller),
      ]);
      addTearDown(container.dispose);

      final List<int> seen = <int>[];
      container.listen<int>(
        _activeLineOf(controller),
        (int? previous, int next) => seen.add(next),
        fireImmediately: true,
      );

      for (final int seconds in <int>[5, 10, 20, 25]) {
        controller.emit(
          controller.state.copyWith(position: Duration(seconds: seconds)),
        );
        await pumpEventQueue();
      }

      // Starts on line one (index 0), then advances once per crossed boundary:
      // 5s stays on line one (no extra event), 10s → 1, 20s → 2, 25s stays.
      expect(seen, <int>[0, 1, 2]);
    });
  });
}
