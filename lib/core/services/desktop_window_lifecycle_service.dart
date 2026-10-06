import 'dart:async';

import '../lifecycle/desktop_close_policy.dart';
import '../lifecycle/platform_shutdown_policy.dart';
import '../models/desktop_close_behavior.dart';
import '../models/playback_state.dart';
import 'background_permission.dart';
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
    BackgroundPermissionRequester? background,
    Duration shutdownDeadline = exitShutdownDeadline,
  })  : _window = window,
        _playback = playback,
        _background = background,
        _shutdownDeadline = shutdownDeadline;

  final DesktopWindowController _window;
  final PlaybackController _playback;

  /// Asks the desktop whether a windowless Linthra may run (#754). Null where
  /// nothing kills an app for having no window: everywhere but the Flatpak.
  final BackgroundPermissionRequester? _background;

  /// How long [quit] waits for the graceful shutdown before ending anyway.
  final Duration _shutdownDeadline;

  StreamSubscription<PlaybackState>? _playbackSubscription;
  StreamSubscription<DesktopWindowVisibility>? _visibilitySubscription;

  DesktopCloseBehavior _behavior = DesktopCloseBehavior.defaultBehavior;
  BackgroundPermission _permission = BackgroundPermission.unknown;
  final StreamController<BackgroundPermission> _permissionChanges =
      StreamController<BackgroundPermission>.broadcast();
  bool? _pushedHideOnClose;
  bool _hidden = false;
  bool _quitting = false;
  Future<void> Function()? _shutdown;

  /// The desktop's last answer about running with the window closed, or
  /// [BackgroundPermission.unknown] before it gave one.
  BackgroundPermission get backgroundPermission => _permission;

  /// Each new answer from the desktop, for the settings card to say why
  /// closing the window quits.
  Stream<BackgroundPermission> get backgroundPermissionChanges =>
      _permissionChanges.stream;

  /// Starts mirroring playback onto the runner. Safe to call more than once.
  void start() {
    _playbackSubscription ??= _playback.stateStream.listen(_onPlaybackState);
    _visibilitySubscription ??= _window.visibility.listen(_onVisibility);
    _sync(_playback.state);
  }

  /// Applies the user's stored choice. Called with the persisted value at
  /// startup and again on every change.
  ///
  /// Choosing to keep playing (and starting up with that choice) also asks
  /// the desktop whether Linthra may run with its window closed (#754). The
  /// window keeps hiding as before while the answer is on its way.
  void setCloseBehavior(DesktopCloseBehavior behavior) {
    if (_behavior == behavior) return;
    _behavior = behavior;
    _sync(_playback.state);
    if (behavior == DesktopCloseBehavior.keepPlaying) {
      unawaited(_askBackground());
    }
  }

  /// Asks the desktop again, for after the user allowed Linthra to run in the
  /// background in the system settings: the option they chose is still the
  /// selected one, so choosing it again changes nothing. Only while keeping
  /// playback running.
  Future<void> recheckBackgroundPermission() async {
    if (_behavior != DesktopCloseBehavior.keepPlaying) return;
    await _askBackground();
  }

  Future<void> _askBackground() async {
    final BackgroundPermissionRequester? background = _background;
    if (background == null || _quitting) return;
    final BackgroundPermission answer = await background.request();
    // Answers that leave things as they were change nothing; "unknown" never
    // overrides an answer the desktop already gave.
    if (answer == BackgroundPermission.unknown || _quitting) return;
    if (answer == _permission) return;
    _permission = answer;
    if (!_permissionChanges.isClosed) _permissionChanges.add(answer);
    _sync(_playback.state);
    // The window was closed while the desktop was still deciding, and hid as
    // keep playing does. Left hidden now, the desktop kills Linthra a few
    // seconds from now, mid-song and with no shutdown: quit the normal way,
    // as closing the window does once the answer is known.
    if (answer == BackgroundPermission.denied && _hidden) {
      unawaited(quit());
    }
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
      // Bounded like closing the window is: a teardown that never finishes
      // (an audio engine that hangs on dispose) must not leave a process with
      // no window running behind the user's back.
      await _shutdown?.call().timeout(_shutdownDeadline);
    } catch (_) {
      // `ApplicationHandle.shutdown` never throws, and a foreign one that does,
      // or one past the deadline, must not keep the process alive.
    }
    await _window.quit();
  }

  /// Releases the subscriptions. The window itself is untouched: disposing
  /// the container is not a reason to close anything the user can see.
  Future<void> dispose() async {
    await _cancelSubscriptions();
    await _permissionChanges.close();
  }

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
    // A refusal makes closing quit, but a close can still reach the runner
    // before it hears so, and hide the window: the same late refusal as in
    // [_askBackground], the other way round.
    if (_hidden && _permission == BackgroundPermission.denied) {
      unawaited(quit());
    }
  }

  void _sync(PlaybackState state) {
    final bool hideOnClose = DesktopClosePolicy.hidesOnClose(
      _behavior,
      state,
      backgroundAllowed: _permission != BackgroundPermission.denied,
    );
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
