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

  group('a load or a stall the listener paused', () {
    // A queue restored at launch loads paused, and so does a load or a
    // reconnect the listener paused (#751, #806): when it lands, nothing
    // plays.
    PlaybackState pausedWhile(PlaybackStatus status) => PlaybackState(
          status: status,
          currentTrack: _track,
          playWhenReady: false,
        );

    test('is nothing to keep playing, so closing the window quits', () {
      for (final PlaybackStatus status in <PlaybackStatus>[
        PlaybackStatus.loading,
        PlaybackStatus.buffering,
        PlaybackStatus.reconnecting,
      ]) {
        expect(
          DesktopClosePolicy.hidesOnClose(
            DesktopCloseBehavior.keepPlaying,
            pausedWhile(status),
          ),
          isFalse,
          reason: 'status $status',
        );
      }
    });

    test('still keeps a hidden app alive, like any pause', () {
      for (final PlaybackStatus status in <PlaybackStatus>[
        PlaybackStatus.loading,
        PlaybackStatus.buffering,
        PlaybackStatus.reconnecting,
      ]) {
        expect(
          DesktopClosePolicy.keepsRunningWhileHidden(pausedWhile(status)),
          isTrue,
          reason: 'status $status',
        );
      }
    });
  });

  group('hidesOnClose when the desktop refused (#754)', () {
    test('keep playing quits instead, even mid-song', () {
      // Inside the Flatpak a hidden window would get the app killed a few
      // seconds later, without its graceful shutdown.
      for (final PlaybackStatus status in PlaybackStatus.values) {
        expect(
          DesktopClosePolicy.hidesOnClose(
            DesktopCloseBehavior.keepPlaying,
            _state(status),
            backgroundAllowed: false,
          ),
          isFalse,
          reason: 'status $status',
        );
      }
    });

    test('allowed is the same as before anyone asked', () {
      expect(
        DesktopClosePolicy.hidesOnClose(
          DesktopCloseBehavior.keepPlaying,
          _state(PlaybackStatus.playing),
          backgroundAllowed: true,
        ),
        isTrue,
      );
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

    test('a failed track keeps the app alive for the recovery that follows',
        () {
      // A stream that dropped and couldn't be recovered, or a Pause pressed
      // in the shell while it was reconnecting (which settles on the
      // failure), still has a queue and a position. Play or Next from the
      // shell's media widget is how the listener gets going again, so the
      // process has to be there to receive it.
      expect(
        DesktopClosePolicy.keepsRunningWhileHidden(
          _state(PlaybackStatus.error),
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
