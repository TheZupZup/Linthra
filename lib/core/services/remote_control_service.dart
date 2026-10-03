import 'dart:async';

import '../models/playback_state.dart';
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
/// commands reach the controller strictly in arrival order, and any failure
/// applying a single command is swallowed so it can never stall the stream or
/// disturb playback. None waits for the one before it to finish, exactly as
/// with on-screen taps: the controller takes each command's intent the moment
/// it is called (the queue moves, a pause holds a load, a seek aims it), and
/// what its future waits for is the next track loading. The exception is a
/// Stop, which the commands after it wait for (see [_drain]).
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

  /// Applies pending commands strictly in order. A failure on one command is
  /// swallowed so the next still runs and playback is never disturbed.
  ///
  /// Each is handed over without waiting for it to finish. Waited for, a
  /// skip held every command behind it until the next track had loaded and
  /// started: three quick Nexts from the remote loaded and played a moment of
  /// each song on the way (and reported each to the server as started), and
  /// a Pause right after a Next let the new track start first.
  ///
  /// A Stop is the one waited for. It settles the player as stopped only once
  /// the engine has let go of its source, so a Play or a Next sent with it
  /// (an automation's "restart", or someone quick on the remote) was undone
  /// when that stop finished. A stop waits on the engine, never on a track
  /// loading.
  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_pending.isNotEmpty) {
        final RemoteCommand command = _pending.removeAt(0);
        if (command is RemoteStop) {
          try {
            await _apply(command);
          } catch (_) {
            // Best-effort by contract; the next command still goes out.
          }
          continue;
        }
        try {
          unawaited(_apply(command).catchError((Object _) {
            // Best-effort by contract.
          }));
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
        // Same test as the in-app button and MPRIS' PlayPause: a stream that
        // is re-buffering or reconnecting is still playback (the sound comes
        // back on its own, and the server still shows it playing), so the
        // toggle has to stop it. Testing `isPlaying` alone called play() then,
        // which changes nothing, and the music carried on.
        final PlaybackState state = _controller.state;
        if (state.isPlaying || state.isBuffering) {
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
