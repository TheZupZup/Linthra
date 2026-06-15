import 'dart:async';

import 'playback_controller.dart';
import 'remote_command.dart';
import 'remote_control_receiver.dart';

/// Applies [RemoteCommand]s from a [RemoteControlReceiver] to the app's
/// [PlaybackController] — the bridge that lets a Plex or Jellyfin remote
/// actually drive playback.
///
/// It listens to the receiver's neutral command stream and calls the *same*
/// [PlaybackController] transport methods the on-screen controls use, so a
/// remote pause and an in-app pause are indistinguishable downstream (both flow
/// through cast routing, the media session, and server reporting). A
/// [RemotePlayPause] toggle consults the controller's live
/// [PlaybackController.state] to decide play vs. pause.
///
/// Like the reporting service, it is best-effort and off the critical path:
/// commands are applied strictly in arrival order, one at a time (so a slow
/// seek can't let a later pause overtake it), and any failure applying a single
/// command is swallowed so it can never stall the stream or disturb playback.
class RemoteControlService {
  RemoteControlService({
    required RemoteControlReceiver receiver,
    required PlaybackController controller,
  }) : _controller = controller {
    _subscription = receiver.commands.listen(_enqueue);
  }

  final PlaybackController _controller;
  late final StreamSubscription<RemoteCommand> _subscription;

  final List<RemoteCommand> _pending = <RemoteCommand>[];
  bool _draining = false;

  void _enqueue(RemoteCommand command) {
    _pending.add(command);
    unawaited(_drain());
  }

  /// Applies pending commands strictly in order, one at a time. A failure on
  /// one command is swallowed so the next still runs and playback is never
  /// disturbed.
  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_pending.isNotEmpty) {
        final RemoteCommand command = _pending.removeAt(0);
        try {
          await _apply(command);
        } catch (_) {
          // Best-effort by contract; the next command still goes out.
        }
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _apply(RemoteCommand command) async {
    switch (command) {
      case RemotePlay():
        await _controller.play();
      case RemotePause():
        await _controller.pause();
      case RemotePlayPause():
        if (_controller.state.isPlaying) {
          await _controller.pause();
        } else {
          await _controller.play();
        }
      case RemoteStop():
        await _controller.stop();
      case RemoteNext():
        await _controller.skipToNext();
      case RemotePrevious():
        await _controller.skipToPrevious();
      case RemoteSeek(:final position):
        await _controller.seek(position);
    }
  }

  /// Stops applying commands. Call when the controllable session ends; the
  /// receiver owns its own transport and is disposed separately.
  Future<void> dispose() async {
    await _subscription.cancel();
  }
}
