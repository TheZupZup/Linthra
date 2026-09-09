import 'dart:async';

import '../lifecycle/desktop_close_policy.dart';
import '../models/desktop_close_behavior.dart';
import '../models/playback_state.dart';
import 'desktop_application_actions.dart';
import 'desktop_window_controller.dart';
import 'playback_controller.dart';

/// Keeps the desktop runner's close behaviour in step with the user's choice
/// and with what playback is doing, and owns the explicit-quit path (#401).
///
/// The runner cannot ask Dart anything inside a GTK `delete-event` handler,
/// because that answer has to be synchronous, so this service *pushes* the
/// decision ahead of time: whenever the preference or the playback state
/// changes it recomputes [DesktopClosePolicy.hidesOnClose] and hands the runner
/// a single boolean. Closing the window is then a local decision the runner
/// can make instantly, and it is always the decision the app would have made.
///
/// It also owns the two things that keep background mode honest:
///
///  * A hidden Linthra whose queue has run out quits itself, so closing the
///    window can never leave a silent process behind.
///  * [quit] releases the app's resources *before* the process ends, rather
///    than relying on the engine to hand out enough time on the way down.
///
/// Inert off the desktop: the controller is then
/// [NoopDesktopWindowController], nothing is ever hidden, and every push is a
/// no-op.
class DesktopWindowLifecycleService implements DesktopApplicationActions {
  DesktopWindowLifecycleService({
    required DesktopWindowController window,
    required PlaybackController playback,
  })  : _window = window,
        _playback = playback;

  final DesktopWindowController _window;
  final PlaybackController _playback;

  StreamSubscription<PlaybackState>? _playbackSubscription;
  StreamSubscription<DesktopWindowVisibility>? _visibilitySubscription;

  DesktopCloseBehavior _behavior = DesktopCloseBehavior.defaultBehavior;
  bool? _pushedHideOnClose;
  bool _hidden = false;
  bool _quitting = false;
  Future<void> Function()? _shutdown;

  /// Whether the window is currently hidden, i.e. Linthra is running in the
  /// background with no window on screen.
  ///
  /// Read by the app's lifecycle observer: on Linux a hide/show cycle looks
  /// exactly like a system suspend/resume, and the post-suspend recovery must
  /// not reload a track that never stopped playing.
  bool get isWindowHidden => _hidden;

  /// Starts mirroring playback onto the runner. Safe to call more than once.
  void start() {
    _playbackSubscription ??= _playback.stateStream.listen(_onPlaybackState);
    _visibilitySubscription ??= _window.visibility.listen(_onVisibility);
    _sync(_playback.state);
  }

  /// Applies the user's stored choice. Called with the persisted value at
  /// startup and again on every change.
  void setCloseBehavior(DesktopCloseBehavior behavior) {
    if (_behavior == behavior) return;
    _behavior = behavior;
    _sync(_playback.state);
  }

  /// Installs the graceful shutdown [quit] runs before the process ends.
  ///
  /// Handed in rather than reached for: the root [ApplicationHandle] is created
  /// by bootstrap, and this service must not have to know how to find it.
  void installShutdown(Future<void> Function() shutdown) {
    _shutdown = shutdown;
  }

  @override
  Future<void> raise() => _window.showWindow();

  @override
  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    // Stop listening first: the shutdown below stops playback, and a state
    // change arriving mid-teardown must not start a second quit or push a
    // close behaviour onto a window that is going away.
    await _cancelSubscriptions();
    try {
      await _shutdown?.call();
    } catch (_) {
      // `ApplicationHandle.shutdown` never throws, and a foreign one that does
      // must not keep the process alive.
    }
    await _window.quit();
  }

  /// Releases the subscriptions. The window itself is untouched: disposing
  /// the container is not a reason to close anything the user can see.
  Future<void> dispose() => _cancelSubscriptions();

  void _onPlaybackState(PlaybackState state) {
    if (_quitting) return;
    _sync(state);
    // The anti-zombie rule: nothing left to play and no window to show for it.
    if (_hidden && !DesktopClosePolicy.keepsRunningWhileHidden(state)) {
      unawaited(quit());
    }
  }

  void _onVisibility(DesktopWindowVisibility visibility) {
    _hidden = visibility == DesktopWindowVisibility.hidden;
  }

  void _sync(PlaybackState state) {
    final bool hideOnClose = DesktopClosePolicy.hidesOnClose(_behavior, state);
    if (_pushedHideOnClose == hideOnClose) return;
    _pushedHideOnClose = hideOnClose;
    unawaited(_window.setHideOnClose(hideOnClose));
  }

  Future<void> _cancelSubscriptions() async {
    final StreamSubscription<PlaybackState>? playback = _playbackSubscription;
    final StreamSubscription<DesktopWindowVisibility>? visibility =
        _visibilitySubscription;
    _playbackSubscription = null;
    _visibilitySubscription = null;
    await playback?.cancel();
    await visibility?.cancel();
  }
}
