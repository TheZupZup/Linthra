import '../models/desktop_close_behavior.dart';
import '../models/playback_state.dart';

/// The two rules behind the configurable close-window behaviour (issue #401),
/// as pure functions of the user's choice and what playback is doing.
///
/// They live here, apart from the widget layer and from the GTK runner, because
/// the interesting part of this feature is not "hide the window", it is
/// deciding *when* hiding it is right. Both rules are exercised directly in
/// tests, on any host, without a window or a session bus.
abstract final class DesktopClosePolicy {
  /// Whether closing the window should hide it and leave Linthra running.
  ///
  /// Two things have to be true: the user asked for it
  /// ([DesktopCloseBehavior.keepPlaying]) *and* there is audio to keep alive.
  /// A closed window with nothing playing simply quits, whatever the
  /// preference says. That is the "no hidden zombie process" half of the
  /// requirement, and it is why the preference alone does not decide.
  static bool hidesOnClose(
    DesktopCloseBehavior behavior,
    PlaybackState state,
  ) {
    if (behavior != DesktopCloseBehavior.keepPlaying) return false;
    return _isProducingAudio(state);
  }

  /// Whether an already-hidden Linthra still has a reason to run.
  ///
  /// Looser than [hidesOnClose] on purpose: once the window is away, the
  /// desktop media controls are the only interface left, so a pause taken from
  /// a shell's media widget has to keep the app alive for the resume that
  /// follows. What ends a hidden session is the queue running out (or being
  /// stopped): no current track, or a status that is not going to produce
  /// sound again on its own.
  static bool keepsRunningWhileHidden(PlaybackState state) {
    if (_isProducingAudio(state)) return true;
    return state.status == PlaybackStatus.paused && state.hasTrack;
  }

  /// Sound now, or the engine working toward it: the states in which stopping
  /// the process would be audible to the listener.
  static bool _isProducingAudio(PlaybackState state) {
    switch (state.status) {
      case PlaybackStatus.playing:
      case PlaybackStatus.loading:
      case PlaybackStatus.buffering:
      case PlaybackStatus.reconnecting:
        return true;
      case PlaybackStatus.idle:
      case PlaybackStatus.paused:
      case PlaybackStatus.completed:
      case PlaybackStatus.error:
        return false;
    }
  }
}
