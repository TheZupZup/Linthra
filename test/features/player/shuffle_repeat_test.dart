import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';

import 'fake_playback_controller.dart';

Track _track(String id) => Track(id: id, title: 'Song $id', uri: '/$id.mp3');

void main() {
  group('shuffle through the controller', () {
    test('toggling shuffle on exposes the state and keeps the current track',
        () async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('a'), _track('b'), _track('c')]);
      expect(controller.state.shuffleEnabled, isFalse);

      controller.setShuffleEnabled(true);

      expect(controller.state.shuffleEnabled, isTrue);
      // The track that was playing keeps playing.
      expect(controller.state.currentTrack, _track('a'));
      // The same set of upcoming tracks remains, just reordered.
      expect(
        {...controller.state.upNext, controller.state.currentTrack},
        {_track('a'), _track('b'), _track('c')},
      );
    });

    test('toggling shuffle off restores order and clears the state', () async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('a'), _track('b'), _track('c')]);

      controller.setShuffleEnabled(true);
      controller.setShuffleEnabled(false);

      expect(controller.state.shuffleEnabled, isFalse);
      expect(controller.state.currentTrack, _track('a'));
      expect(controller.state.upNext, [_track('b'), _track('c')]);
    });

    test('a queue loaded while shuffle is on starts shuffled', () async {
      final controller = FakePlaybackController();
      controller.setShuffleEnabled(true);

      await controller.playTracks([_track('a'), _track('b'), _track('c')]);

      expect(controller.state.shuffleEnabled, isTrue);
      expect(
        {...controller.state.upNext, controller.state.currentTrack},
        {_track('a'), _track('b'), _track('c')},
      );
    });
  });

  group('repeat through the controller', () {
    test('setRepeatMode exposes the mode in state', () async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('a')]);
      expect(controller.state.repeatMode, RepeatMode.off);

      controller.setRepeatMode(RepeatMode.all);
      expect(controller.state.repeatMode, RepeatMode.all);

      controller.setRepeatMode(RepeatMode.one);
      expect(controller.state.repeatMode, RepeatMode.one);
    });

    test('repeat off stops at the end of the queue', () async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('a'), _track('b')]);

      controller.completeCurrent(); // a -> b
      expect(controller.state.currentTrack, _track('b'));

      controller.completeCurrent(); // b is last; with repeat off, stop
      expect(controller.state.currentTrack, _track('b'));
      expect(controller.state.status.name, 'completed');
    });

    test('repeat all wraps from the last track back to the first', () async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('a'), _track('b')]);
      controller.setRepeatMode(RepeatMode.all);

      controller.completeCurrent(); // a -> b
      expect(controller.state.currentTrack, _track('b'));

      controller.completeCurrent(); // b is last; wrap back to a
      expect(controller.state.currentTrack, _track('a'));
      expect(controller.state.upNext, [_track('b')]);
    });

    test('repeat one replays the same track when it finishes', () async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('a'), _track('b')]);
      controller.setRepeatMode(RepeatMode.one);

      controller.completeCurrent();
      controller.completeCurrent();

      // Still on the first track, having played it three times in total.
      expect(controller.state.currentTrack, _track('a'));
      expect(controller.playedTracks, [_track('a'), _track('a'), _track('a')]);
    });

    test('next/previous still advance normally regardless of repeat mode',
        () async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('a'), _track('b'), _track('c')]);
      controller.setRepeatMode(RepeatMode.one);

      await controller.skipToNext();
      expect(controller.state.currentTrack, _track('b'));

      await controller.skipToPrevious();
      expect(controller.state.currentTrack, _track('a'));
    });
  });
}
