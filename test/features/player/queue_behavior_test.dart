import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';

import 'fake_playback_controller.dart';

Track _track(String id) => Track(id: id, title: 'Song $id', uri: '/$id.mp3');

void main() {
  group('queue behavior through the controller', () {
    test('playTracks sets the current track and the up-next list', () async {
      final controller = FakePlaybackController();

      await controller.playTracks(
        [_track('a'), _track('b'), _track('c')],
        startIndex: 0,
      );

      expect(controller.state.currentTrack, _track('a'));
      expect(controller.state.upNext, [_track('b'), _track('c')]);
      expect(controller.state.hasNext, isTrue);
    });

    test('playNext queues a track after the current one', () async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('a'), _track('c')]);

      controller.playNext(_track('b'));

      expect(controller.state.currentTrack, _track('a'));
      expect(controller.state.upNext, [_track('b'), _track('c')]);
    });

    test('skipToNext advances to the next track', () async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('a'), _track('b')]);

      await controller.skipToNext();

      expect(controller.state.currentTrack, _track('b'));
      expect(controller.state.hasNext, isFalse);
      expect(controller.playedTracks, [_track('a'), _track('b')]);
    });

    test('skipToNext with an empty queue is a no-op on the current track',
        () async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('a')]);

      await controller.skipToNext();

      expect(controller.state.currentTrack, _track('a'));
    });

    test('skipToPrevious steps back and reports a previous track', () async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('a'), _track('b'), _track('c')]);
      await controller.skipToNext();
      await controller.skipToNext();
      expect(controller.state.currentTrack, _track('c'));

      await controller.skipToPrevious();

      expect(controller.state.currentTrack, _track('b'));
      expect(controller.state.hasPrevious, isTrue);
      expect(controller.state.upNext, [_track('c')]);
    });

    test('skipToPrevious on the first track is a no-op', () async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('a'), _track('b')]);

      await controller.skipToPrevious();

      expect(controller.state.currentTrack, _track('a'));
      expect(controller.state.hasPrevious, isFalse);
    });

    test('clearQueue empties up next but keeps the current track', () async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('a'), _track('b'), _track('c')]);

      controller.clearQueue();

      expect(controller.state.currentTrack, _track('a'));
      expect(controller.state.upNext, isEmpty);
      expect(controller.state.hasNext, isFalse);
    });

    test('addToQueue appends a track to the end', () async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('a'), _track('b')]);

      controller.addToQueue(_track('c'));

      expect(controller.state.currentTrack, _track('a'));
      expect(controller.state.upNext, [_track('b'), _track('c')]);
    });

    test('addToQueue on an empty queue starts playback', () async {
      final controller = FakePlaybackController();

      controller.addToQueue(_track('a'));

      expect(controller.state.currentTrack, _track('a'));
      expect(controller.playedTracks, [_track('a')]);
    });

    test('playNext on an empty queue starts playback', () async {
      final controller = FakePlaybackController();

      controller.playNext(_track('a'));

      expect(controller.state.currentTrack, _track('a'));
      expect(controller.playedTracks, [_track('a')]);
    });

    test('removeFromQueue drops only that up-next entry', () async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('a'), _track('b'), _track('c')]);

      // up next is [b, c]; remove index 0 (b).
      controller.removeFromQueue(0);

      expect(controller.state.currentTrack, _track('a'));
      expect(controller.state.upNext, [_track('c')]);
    });

    test('reorderQueue moves an up-next track', () async {
      final controller = FakePlaybackController();
      await controller.playTracks(
        [_track('a'), _track('b'), _track('c'), _track('d')],
      );

      // up next is [b, c, d]; move b (0) to the end (2).
      controller.reorderQueue(0, 2);

      expect(controller.state.upNext, [_track('c'), _track('d'), _track('b')]);
    });

    test('playFromQueue jumps to and plays the chosen up-next track', () async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('a'), _track('b'), _track('c')]);

      // up next is [b, c]; play c (index 1).
      await controller.playFromQueue(1);

      expect(controller.state.currentTrack, _track('c'));
      expect(controller.playedTracks, [_track('a'), _track('c')]);
    });

    test('queue edits do not restart the current track', () async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('a'), _track('b'), _track('c')]);
      final int playedBefore = controller.playedTracks.length;

      controller.addToQueue(_track('d'));
      controller.removeFromQueue(0); // removes b
      controller.reorderQueue(0, 1); // reorders the remaining up-next

      // The current track is still 'a' and was never re-played by any edit.
      expect(controller.state.currentTrack, _track('a'));
      expect(controller.playedTracks.length, playedBefore);
    });
  });
}
