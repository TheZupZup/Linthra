import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/services/remote_command.dart';
import 'package:linthra/core/services/remote_control_activator.dart';
import 'package:linthra/core/services/remote_control_receiver.dart';

/// A [RemoteControlReceiver] that just counts start/stop, so the activator's
/// gating can be asserted without any real transport.
class _RecordingReceiver implements RemoteControlReceiver {
  int starts = 0;
  int stops = 0;
  final StreamController<RemoteCommand> _commands =
      StreamController<RemoteCommand>.broadcast();

  @override
  Stream<RemoteCommand> get commands => _commands.stream;

  @override
  Future<void> start() async {
    starts++;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {
    await _commands.close();
  }
}

void main() {
  late StreamController<PlaybackState> states;
  late _RecordingReceiver receiver;
  late RemoteControlActivator activator;

  setUp(() {
    states = StreamController<PlaybackState>.broadcast();
    receiver = _RecordingReceiver();
    activator = RemoteControlActivator(
      receiver: receiver,
      playbackStates: states.stream,
      isControllable: (PlaybackState state) =>
          state.status == PlaybackStatus.playing,
    );
  });

  tearDown(() async {
    await activator.dispose();
    await receiver.dispose();
    await states.close();
  });

  Future<void> push(PlaybackStatus status) async {
    states.add(PlaybackState.idle.copyWith(status: status));
    await pumpEventQueue();
  }

  test('starts the receiver when a state becomes controllable', () async {
    await push(PlaybackStatus.playing);
    expect(receiver.starts, 1);
    expect(receiver.stops, 0);
  });

  test('stops the receiver when it stops being controllable', () async {
    await push(PlaybackStatus.playing);
    await push(PlaybackStatus.paused);
    expect(receiver.starts, 1);
    expect(receiver.stops, 1);
  });

  test('does not restart while it stays controllable', () async {
    await push(PlaybackStatus.playing);
    await push(PlaybackStatus.playing);
    expect(receiver.starts, 1);
  });

  test('does nothing for a non-controllable state', () async {
    await push(PlaybackStatus.idle);
    expect(receiver.starts, 0);
    expect(receiver.stops, 0);
  });
}
