import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';

Track _jelly(String id) => Track(id: id, title: 't', uri: 'jellyfin:$id');
Track _sub(String id) => Track(id: id, title: 't', uri: 'subsonic:$id');

void main() {
  group('PlaybackState ==', () {
    test('up-next reordered among same-bare-id copies is not equal', () {
      // Reordering two same-id copies from different providers must change
      // equality (Track == is uri-based) so the controller's _emit guard does
      // not drop the new queue while the internal queue advances in the new
      // order.
      const PlaybackState a = PlaybackState(
        status: PlaybackStatus.playing,
        upNext: <Track>[],
      );
      final PlaybackState before = a.copyWith(
        currentTrack: _jelly('1'),
        upNext: <Track>[_jelly('101'), _sub('101')],
      );
      final PlaybackState after = a.copyWith(
        currentTrack: _jelly('1'),
        upNext: <Track>[_sub('101'), _jelly('101')],
      );
      expect(before, isNot(after));
    });

    test('a current-track provider swap with the same bare id is not equal', () {
      final PlaybackState a = const PlaybackState(status: PlaybackStatus.playing)
          .copyWith(currentTrack: _jelly('101'));
      final PlaybackState b = const PlaybackState(status: PlaybackStatus.playing)
          .copyWith(currentTrack: _sub('101'));
      expect(a, isNot(b));
    });

    test('identical states stay equal and hash the same', () {
      final PlaybackState a = const PlaybackState(status: PlaybackStatus.playing)
          .copyWith(currentTrack: _jelly('101'), upNext: <Track>[_jelly('2')]);
      final PlaybackState b = const PlaybackState(status: PlaybackStatus.playing)
          .copyWith(currentTrack: _jelly('101'), upNext: <Track>[_jelly('2')]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });
}
