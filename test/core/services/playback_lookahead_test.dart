import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/playback_lookahead.dart';

Track _t(String id, {String provider = 'jellyfin'}) =>
    Track(id: id, title: id, uri: '$provider:$id');

PlaybackState _state(
  Track? current,
  List<Track> upNext, {
  Duration position = Duration.zero,
  bool shuffle = false,
  RepeatMode repeat = RepeatMode.off,
  PlaybackStatus status = PlaybackStatus.playing,
}) =>
    PlaybackState(
      status: status,
      currentTrack: current,
      upNext: upNext,
      position: position,
      shuffleEnabled: shuffle,
      repeatMode: repeat,
    );

void main() {
  group('upcomingTracks', () {
    test('follows the queue order, bounded by the count', () {
      final PlaybackState state = _state(
        _t('a'),
        <Track>[_t('b'), _t('c'), _t('d'), _t('e')],
      );

      expect(
        upcomingTracks(state, count: 3).map((Track t) => t.id),
        <String>['b', 'c', 'd'],
      );
    });

    test('follows the shuffled order the controller already made', () {
      // The controller's up-next is the shuffled play order; warming its head
      // must not fall back to album order.
      final PlaybackState state = _state(
        _t('a'),
        <Track>[_t('d'), _t('b'), _t('c')],
        shuffle: true,
      );

      expect(
        upcomingTracks(state, count: 2).map((Track t) => t.id),
        <String>['d', 'b'],
      );
    });

    test('repeat-all wraps to the start of the queue once up-next runs out',
        () {
      final PlaybackState state = PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: _t('c'),
        upNext: <Track>[_t('d')],
        previous: <Track>[_t('a'), _t('b')],
        repeatMode: RepeatMode.all,
      );

      expect(
        upcomingTracks(state, count: 3).map((Track t) => t.id),
        <String>['d', 'a', 'b'],
      );
    });

    test('without repeat-all the end of the queue is the end', () {
      final PlaybackState state = PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: _t('c'),
        upNext: <Track>[_t('d')],
        previous: <Track>[_t('a'), _t('b')],
      );

      expect(
        upcomingTracks(state, count: 3).map((Track t) => t.id),
        <String>['d'],
      );
    });

    test('repeat-one warms nothing: the current track loops', () {
      final PlaybackState state = _state(
        _t('a'),
        <Track>[_t('b')],
        repeat: RepeatMode.one,
      );

      expect(upcomingTracks(state, count: 3), isEmpty);
    });

    test('a track queued twice, or the current one, is warmed once', () {
      final PlaybackState state = _state(
        _t('a'),
        <Track>[_t('b'), _t('a'), _t('b'), _t('c')],
      );

      expect(
        upcomingTracks(state, count: 3).map((Track t) => t.id),
        <String>['b', 'c'],
      );
    });

    test('same id from another provider is a different track', () {
      final PlaybackState state = _state(
        _t('1'),
        <Track>[_t('1', provider: 'subsonic'), _t('2')],
      );

      expect(
        upcomingTracks(state, count: 2).map((Track t) => t.uri),
        <String>['subsonic:1', 'jellyfin:2'],
      );
    });

    test('a huge queue costs no more than its window', () {
      final PlaybackState state = _state(
        _t('cur'),
        <Track>[for (int i = 0; i < 5000; i++) _t('$i')],
      );

      expect(upcomingTracks(state, count: 3), hasLength(3));
      expect(upcomingTracks(_state(null, <Track>[_t('b')]), count: 3), isEmpty);
    });
  });

  group('samePlaybackLookahead', () {
    test('a position tick is the same work', () {
      final List<Track> upNext = <Track>[_t('2'), _t('3')];
      final PlaybackState first = _state(_t('1'), upNext);
      // Exactly how the controller emits a tick: the queue objects are handed
      // through untouched, only the position moves.
      final PlaybackState tick =
          first.copyWith(position: const Duration(seconds: 7));

      expect(samePlaybackLookahead(first, tick, ahead: 3), isTrue);
    });

    test('a status change alone is the same work', () {
      final PlaybackState playing = _state(_t('1'), <Track>[_t('2')]);
      final PlaybackState paused =
          playing.copyWith(status: PlaybackStatus.paused);

      expect(samePlaybackLookahead(playing, paused, ahead: 3), isTrue);
    });

    test('a null state never matches, so the first emission always runs', () {
      final PlaybackState state = _state(_t('1'), <Track>[_t('2')]);

      expect(samePlaybackLookahead(state, null, ahead: 3), isFalse);
      expect(samePlaybackLookahead(null, state, ahead: 3), isFalse);
    });

    test('a track change is different work', () {
      final List<Track> upNext = <Track>[_t('2')];

      expect(
        samePlaybackLookahead(
          _state(_t('1'), upNext),
          _state(_t('9'), upNext),
          ahead: 3,
        ),
        isFalse,
      );
    });

    test('a same-id copy from another provider is different work', () {
      // The fallback that swaps jellyfin:101 for subsonic:101 keeps the bare id
      // but is a different copy to warm.
      expect(
        samePlaybackLookahead(
          _state(_t('101'), const <Track>[]),
          _state(_t('101', provider: 'subsonic'), const <Track>[]),
          ahead: 3,
        ),
        isFalse,
      );
    });

    test('shuffle and repeat changes are different work', () {
      final Track current = _t('1');
      final List<Track> upNext = <Track>[_t('2')];

      expect(
        samePlaybackLookahead(
          _state(current, upNext),
          _state(current, upNext, shuffle: true),
          ahead: 3,
        ),
        isFalse,
      );
      expect(
        samePlaybackLookahead(
          _state(current, upNext),
          _state(current, upNext, repeat: RepeatMode.one),
          ahead: 3,
        ),
        isFalse,
      );
    });

    test('a rebuilt but equal queue still compares as the same work', () {
      // Identity is only the fast path; equal contents must still match, or a
      // queue rebuilt for unrelated reasons would re-trigger a warm.
      expect(
        samePlaybackLookahead(
          _state(_t('1'), <Track>[_t('2'), _t('3')]),
          _state(_t('1'), <Track>[_t('2'), _t('3')]),
          ahead: 3,
        ),
        isTrue,
      );
    });

    test('a change inside the look-ahead is different work', () {
      expect(
        samePlaybackLookahead(
          _state(_t('1'), <Track>[_t('2'), _t('3')]),
          _state(_t('1'), <Track>[_t('2'), _t('4')]),
          ahead: 3,
        ),
        isFalse,
      );
    });

    test('a change past the look-ahead is not work at all', () {
      // Only the head of up-next is ever warmed, so a queue edit 50 tracks out
      // must not wake anything up.
      final List<Track> head = <Track>[_t('2'), _t('3')];
      expect(
        samePlaybackLookahead(
          _state(_t('1'), <Track>[...head, _t('50')]),
          _state(_t('1'), <Track>[...head, _t('51')]),
          ahead: 2,
        ),
        isTrue,
      );
    });

    test('a shorter queue is different work even past the look-ahead', () {
      // Reaching the end of the queue matters: there is nothing left to warm.
      expect(
        samePlaybackLookahead(
          _state(_t('1'), <Track>[_t('2'), _t('3')]),
          _state(_t('1'), <Track>[_t('2')]),
          ahead: 5,
        ),
        isFalse,
      );
    });
  });
}
