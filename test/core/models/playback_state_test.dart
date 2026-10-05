import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_failure.dart';
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

    test('a current-track provider swap with the same bare id is not equal',
        () {
      final PlaybackState a =
          const PlaybackState(status: PlaybackStatus.playing)
              .copyWith(currentTrack: _jelly('101'));
      final PlaybackState b =
          const PlaybackState(status: PlaybackStatus.playing)
              .copyWith(currentTrack: _sub('101'));
      expect(a, isNot(b));
    });

    test('identical states stay equal and hash the same', () {
      final PlaybackState a =
          const PlaybackState(status: PlaybackStatus.playing).copyWith(
              currentTrack: _jelly('101'), upNext: <Track>[_jelly('2')]);
      final PlaybackState b =
          const PlaybackState(status: PlaybackStatus.playing).copyWith(
              currentTrack: _jelly('101'), upNext: <Track>[_jelly('2')]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('copyWith and the failure', () {
    const PlaybackFailure failure = PlaybackFailure(
      kind: PlaybackFailureKind.temporarySource,
      message: "Couldn't reach your music server.",
      canRetry: true,
    );
    final PlaybackState failed = PlaybackState(
      status: PlaybackStatus.error,
      currentTrack: _jelly('1'),
      position: const Duration(seconds: 42),
      failure: failure,
    );

    test('an unrelated change to an error state keeps its failure', () {
      expect(failed.copyWith(position: Duration.zero).failure, failure);
      expect(failed.copyWith(shuffleEnabled: true).failure, failure);
      expect(failed.copyWith(upNext: <Track>[_jelly('2')]).failure, failure);
    });

    test('leaving the error state drops it', () {
      expect(failed.copyWith(status: PlaybackStatus.playing).failure, isNull);
      expect(failed.copyWith(status: PlaybackStatus.loading).failure, isNull);
    });

    test('another track, even one sharing the bare id, drops it', () {
      expect(failed.copyWith(currentTrack: _jelly('2')).failure, isNull);
      expect(failed.copyWith(currentTrack: _sub('1')).failure, isNull);
    });

    test('a replacement failure can be given explicitly', () {
      const PlaybackFailure refreshed = PlaybackFailure(
        kind: PlaybackFailureKind.temporarySource,
        message: "Couldn't reach your music server.",
        canRetry: true,
        canSkip: true,
      );
      expect(failed.copyWith(failure: refreshed).failure, refreshed);
      expect(
        const PlaybackState(status: PlaybackStatus.playing)
            .copyWith(failure: refreshed)
            .failure,
        isNull,
        reason: 'a failure only ever rides on an error state',
      );
    });
  });

  group('playWhenReady (#751)', () {
    const PlaybackState stalled = PlaybackState(
      status: PlaybackStatus.buffering,
      playWhenReady: false,
    );

    test('defaults to true, so a busy state reads as before', () {
      expect(const PlaybackState().playWhenReady, isTrue);
      expect(PlaybackState.idle.playWhenReady, isTrue);
    });

    test('is part of equality, so a pause mid-stall is never dropped', () {
      expect(stalled, isNot(stalled.withPlayWhenReady(true)));
      expect(stalled, stalled.copyWith());
      expect(stalled.hashCode, stalled.copyWith().hashCode);
    });

    test('survives copyWith and every re-stamp', () {
      expect(stalled.copyWith(status: PlaybackStatus.loading).playWhenReady,
          isFalse);
      expect(
          stalled.withTransientFocusInterruption(true).playWhenReady, isFalse);
      expect(
          stalled.withVolume(volume: 0.5, muted: true).playWhenReady, isFalse);
      expect(stalled.withAutoSkip(null).playWhenReady, isFalse);
      expect(stalled.copyWith(playWhenReady: true).playWhenReady, isTrue);
    });

    test('re-stamping it keeps a failure', () {
      final PlaybackState failed = PlaybackState(
        status: PlaybackStatus.error,
        currentTrack: _jelly('1'),
        failure: const PlaybackFailure(
          kind: PlaybackFailureKind.temporarySource,
          message: "Couldn't reach your music server.",
        ),
      );
      expect(failed.withPlayWhenReady(false).failure, failed.failure);
    });
  });
}
