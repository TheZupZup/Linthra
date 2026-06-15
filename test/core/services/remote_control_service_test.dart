import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/services/remote_command.dart';
import 'package:linthra/core/services/remote_control_receiver.dart';
import 'package:linthra/core/services/remote_control_service.dart';

import '../../features/player/fake_playback_controller.dart';

/// A [RemoteControlReceiver] driven directly by a test [StreamController], so a
/// test can push neutral commands without any real transport.
class _StreamReceiver implements RemoteControlReceiver {
  _StreamReceiver(this._commands);

  final StreamController<RemoteCommand> _commands;

  @override
  Stream<RemoteCommand> get commands => _commands.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  late StreamController<RemoteCommand> commands;
  late FakePlaybackController controller;
  late RemoteControlService service;

  setUp(() {
    commands = StreamController<RemoteCommand>.broadcast();
    controller = FakePlaybackController();
    service = RemoteControlService(
      receiver: _StreamReceiver(commands),
      controller: controller,
    );
  });

  tearDown(() async {
    await service.dispose();
    await controller.dispose();
    await commands.close();
  });

  Future<void> send(RemoteCommand command) async {
    commands.add(command);
    await pumpEventQueue();
  }

  test('play command starts the controller', () async {
    await send(const RemotePlay());
    expect(controller.playCount, 1);
    expect(controller.pauseCount, 0);
  });

  test('pause command pauses the controller', () async {
    await send(const RemotePause());
    expect(controller.pauseCount, 1);
  });

  test('stop command stops the controller', () async {
    await send(const RemoteStop());
    expect(controller.stopCount, 1);
  });

  test('next command skips to the next track', () async {
    await send(const RemoteNext());
    expect(controller.skipCount, 1);
  });

  test('previous command steps to the previous track', () async {
    await send(const RemotePrevious());
    expect(controller.previousCount, 1);
  });

  test('seek command seeks to the requested position', () async {
    await send(const RemoteSeek(Duration(seconds: 42)));
    expect(controller.seeks, <Duration>[const Duration(seconds: 42)]);
  });

  test('play/pause toggles to pause while playing', () async {
    controller.emit(
      PlaybackState.idle.copyWith(status: PlaybackStatus.playing),
    );
    await send(const RemotePlayPause());
    expect(controller.pauseCount, 1);
    expect(controller.playCount, 0);
  });

  test('play/pause toggles to play while not playing', () async {
    // The default fake state is idle (not playing).
    await send(const RemotePlayPause());
    expect(controller.playCount, 1);
    expect(controller.pauseCount, 0);
  });

  test('a burst of commands all apply', () async {
    commands.add(const RemotePlay());
    commands.add(const RemoteSeek(Duration(seconds: 5)));
    commands.add(const RemotePause());
    await pumpEventQueue();
    expect(controller.playCount, 1);
    expect(controller.seeks, <Duration>[const Duration(seconds: 5)]);
    expect(controller.pauseCount, 1);
  });

  test('no command is applied after dispose', () async {
    await service.dispose();
    commands.add(const RemotePlay());
    await pumpEventQueue();
    expect(controller.playCount, 0);
  });

  test('a no-op receiver drives nothing', () async {
    final RemoteControlService idle = RemoteControlService(
      receiver: const NoOpRemoteControlReceiver(),
      controller: controller,
    );
    await pumpEventQueue();
    expect(controller.playCount, 0);
    expect(controller.pauseCount, 0);
    await idle.dispose();
  });
}
