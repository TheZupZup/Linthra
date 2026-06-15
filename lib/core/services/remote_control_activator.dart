import 'dart:async';

import '../models/playback_state.dart';
import 'remote_control_receiver.dart';

/// Starts and stops a [RemoteControlReceiver] in step with playback, so a
/// provider's remote-control transport (e.g. the Jellyfin control WebSocket) is
/// connected only while it is actually useful — never as a persistent
/// background keep-alive.
///
/// It watches the unified playback state and, whenever [isControllable] turns
/// true, [RemoteControlReceiver.start]s the receiver; when it turns false, it
/// [RemoteControlReceiver.stop]s it. With nothing controllable playing there is
/// no open socket, keeping remote control battery-friendly and consistent with
/// Linthra's "event-driven, never polled" stance. The receiver's command stream
/// stays alive across start/stop, so the [RemoteControlService] consuming it is
/// unaffected.
class RemoteControlActivator {
  RemoteControlActivator({
    required RemoteControlReceiver receiver,
    required Stream<PlaybackState> playbackStates,
    required bool Function(PlaybackState state) isControllable,
  })  : _receiver = receiver,
        _isControllable = isControllable {
    _subscription = playbackStates.listen(_onState);
  }

  final RemoteControlReceiver _receiver;
  final bool Function(PlaybackState state) _isControllable;
  late final StreamSubscription<PlaybackState> _subscription;

  bool _active = false;

  void _onState(PlaybackState state) {
    final bool want = _isControllable(state);
    if (want == _active) return;
    _active = want;
    if (want) {
      unawaited(_receiver.start());
    } else {
      unawaited(_receiver.stop());
    }
  }

  /// Stops watching and disconnects the receiver. The receiver itself is owned
  /// (and finally disposed) by its provider.
  Future<void> dispose() async {
    await _subscription.cancel();
    await _receiver.stop();
  }
}
