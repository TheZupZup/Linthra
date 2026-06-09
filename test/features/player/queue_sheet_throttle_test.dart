import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/player/player_providers.dart';

import 'fake_playback_controller.dart';

/// Battery-sensitive contract for the Queue sheet.
///
/// The sheet selects only the queue identity — `(currentTrack, upNext,
/// previous)` — from the unified playback state (see `QueueSheet.build`), so the
/// whole sheet (history, current, and the reorderable up-next list) does not
/// rebuild on every ~4 Hz position tick while it is open. These tests exercise
/// that exact selection through a [ProviderContainer]: position ticks reuse the
/// same list instances (so the record compares equal and nothing rebuilds),
/// while a real queue edit swaps the list and does rebuild.
Track _track(String id) =>
    Track(id: id, title: 'Song $id', uri: '/$id.mp3', artistName: 'Artist $id');

/// Mirrors `QueueSheet.build`'s selection of the queue identity.
ProviderListenable<(Track?, List<Track>, List<Track>)> _queueOf(
  FakePlaybackController controller,
) {
  return playbackStateProvider.select((s) {
    final PlaybackState state = s.valueOrNull ?? controller.state;
    return (state.currentTrack, state.upNext, state.previous);
  });
}

void main() {
  group('QueueSheet rebuild throttling', () {
    test('position ticks do not rebuild the queue identity', () async {
      final controller = FakePlaybackController();
      addTearDown(controller.dispose);
      await controller
          .playTracks(<Track>[_track('A'), _track('B'), _track('C')]);

      final container = ProviderContainer(overrides: <Override>[
        playbackControllerProvider.overrideWithValue(controller),
      ]);
      addTearDown(container.dispose);

      int rebuilds = 0;
      container.listen<(Track?, List<Track>, List<Track>)>(
        _queueOf(controller),
        (_, __) => rebuilds++,
        fireImmediately: true,
      );
      expect(rebuilds, 1, reason: 'the initial selection');

      // Pure position ticks: copyWith carries the same up-next/history list
      // instances through, so the selected record is unchanged — no rebuild.
      for (final int ms in <int>[500, 1000, 2000, 3000]) {
        controller.emit(
          controller.state.copyWith(position: Duration(milliseconds: ms)),
        );
        await pumpEventQueue();
      }
      expect(
        rebuilds,
        1,
        reason: 'position ticks must not rebuild the whole queue sheet',
      );
    });

    test('a queue edit does rebuild the queue identity', () async {
      final controller = FakePlaybackController();
      addTearDown(controller.dispose);
      await controller
          .playTracks(<Track>[_track('A'), _track('B'), _track('C')]);

      final container = ProviderContainer(overrides: <Override>[
        playbackControllerProvider.overrideWithValue(controller),
      ]);
      addTearDown(container.dispose);

      int rebuilds = 0;
      container.listen<(Track?, List<Track>, List<Track>)>(
        _queueOf(controller),
        (_, __) => rebuilds++,
        fireImmediately: true,
      );
      expect(rebuilds, 1);

      // Removing an up-next entry swaps the list instance → the record differs
      // → exactly one rebuild for a real queue change.
      controller.removeFromQueue(0);
      await pumpEventQueue();
      expect(rebuilds, 2);
      expect(controller.state.upNext, <Track>[_track('C')]);

      // A position tick after the edit still does not rebuild.
      controller.emit(
        controller.state.copyWith(position: const Duration(seconds: 4)),
      );
      await pumpEventQueue();
      expect(rebuilds, 2);
    });
  });
}
