import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/default_play_history_repository.dart';
import 'package:linthra/data/repositories/in_memory_play_history_store.dart';

import 'fake_playback_controller.dart';

Track _t(String id) => Track(id: id, title: 'Title $id', uri: 'jellyfin:$id');

/// Wires the controller's completion callback to play history exactly as
/// `localPlaybackControllerProvider` does in the app, then drives completions
/// through the fake controller's `completeCurrent` test seam (which mirrors
/// `JustAudioPlaybackController._onCompleted`).
void main() {
  group('play history recording on completion', () {
    late InMemoryPlayHistoryStore store;
    late DefaultPlayHistoryRepository history;
    late FakePlaybackController controller;

    setUp(() {
      store = InMemoryPlayHistoryStore();
      history = DefaultPlayHistoryRepository(store: store);
      controller = FakePlaybackController(
        onTrackCompleted: (Track track) =>
            unawaited(history.recordCompletion(track)),
      );
      addTearDown(history.dispose);
      addTearDown(controller.dispose);
    });

    test('completing a track increments its play count', () async {
      await controller.playTracks(<Track>[_t('a'), _t('b')]);

      controller.completeCurrent(); // 'a' finishes, 'b' starts
      await Future<void>.delayed(Duration.zero);
      expect(history.current.playCountFor('jellyfin:a'), 1);
      expect(history.current.playCountFor('jellyfin:b'), 0);

      controller.completeCurrent(); // 'b' finishes (queue ends)
      await Future<void>.delayed(Duration.zero);
      expect(history.current.playCountFor('jellyfin:b'), 1);
    });

    test('repeat-one counts each completed loop as a play', () async {
      await controller.playTracks(<Track>[_t('a')]);
      controller.setRepeatMode(RepeatMode.one);

      controller.completeCurrent();
      controller.completeCurrent();
      await Future<void>.delayed(Duration.zero);

      expect(history.current.playCountFor('jellyfin:a'), 2);
    });

    test('skipping a track does NOT count as a play', () async {
      await controller.playTracks(<Track>[_t('a'), _t('b')]);

      await controller.skipToNext(); // user skip, not a completion
      await Future<void>.delayed(Duration.zero);

      expect(history.current.hasPlayed('jellyfin:a'), isFalse);
      expect(history.current.hasPlayed('jellyfin:b'), isFalse);
    });
  });
}
