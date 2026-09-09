import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/lifecycle/desktop_close_policy.dart';
import 'package:linthra/core/models/desktop_close_behavior.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';

const Track _track = Track(id: 't1', title: 'A Song', uri: '/music/a.flac');

PlaybackState _state(PlaybackStatus status, {bool withTrack = true}) {
  return PlaybackState(
    status: status,
    currentTrack: withTrack ? _track : null,
  );
}

void main() {
  group('hidesOnClose', () {
    test('quit never hides the window, whatever playback is doing', () {
      for (final PlaybackStatus status in PlaybackStatus.values) {
        expect(
          DesktopClosePolicy.hidesOnClose(
            DesktopCloseBehavior.quit,
            _state(status),
          ),
          isFalse,
          reason: 'status $status',
        );
      }
    });

    test('keep playing hides the window while audio is on its way out', () {
      for (final PlaybackStatus status in <PlaybackStatus>[
        PlaybackStatus.playing,
        PlaybackStatus.loading,
        PlaybackStatus.buffering,
        PlaybackStatus.reconnecting,
      ]) {
        expect(
          DesktopClosePolicy.hidesOnClose(
            DesktopCloseBehavior.keepPlaying,
            _state(status),
          ),
          isTrue,
          reason: 'status $status',
        );
      }
    });

    test('keep playing still quits when there is nothing to keep playing', () {
      // The "no hidden zombie process" rule: the preference alone never hides
      // a window. Pausing counts as nothing to keep alive, because a paused
      // player the listener just closed is not background playback.
      for (final PlaybackStatus status in <PlaybackStatus>[
        PlaybackStatus.idle,
        PlaybackStatus.paused,
        PlaybackStatus.completed,
        PlaybackStatus.error,
      ]) {
        expect(
          DesktopClosePolicy.hidesOnClose(
            DesktopCloseBehavior.keepPlaying,
            _state(status),
          ),
          isFalse,
          reason: 'status $status',
        );
      }
    });
  });

  group('keepsRunningWhileHidden', () {
    test('playing, buffering and reconnecting all keep the app alive', () {
      for (final PlaybackStatus status in <PlaybackStatus>[
        PlaybackStatus.playing,
        PlaybackStatus.loading,
        PlaybackStatus.buffering,
        PlaybackStatus.reconnecting,
      ]) {
        expect(
          DesktopClosePolicy.keepsRunningWhileHidden(_state(status)),
          isTrue,
          reason: 'status $status',
        );
      }
    });

    test('a pause taken from the media controls keeps the app alive', () {
      // With no window on screen, the shell's media widget is the only
      // interface left: a pause there has to survive long enough to be resumed
      // from the same widget.
      expect(
        DesktopClosePolicy.keepsRunningWhileHidden(
          _state(PlaybackStatus.paused),
        ),
        isTrue,
      );
    });

    test('the queue running out ends a hidden session', () {
      for (final PlaybackState state in <PlaybackState>[
        _state(PlaybackStatus.completed),
        _state(PlaybackStatus.idle, withTrack: false),
        _state(PlaybackStatus.paused, withTrack: false),
        _state(PlaybackStatus.error, withTrack: false),
      ]) {
        expect(
          DesktopClosePolicy.keepsRunningWhileHidden(state),
          isFalse,
          reason: 'status ${state.status}',
        );
      }
    });
  });
}
