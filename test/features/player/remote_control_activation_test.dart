import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/remote_command.dart';
import 'package:linthra/core/services/remote_control_receiver.dart';
import 'package:linthra/features/player/player_providers.dart';

import 'fake_playback_controller.dart';

/// Jellyfin remote control as the server sees it: a command another Jellyfin
/// app sends reaches Linthra only over the control socket that is open at
/// that moment. With no socket open the server has nowhere to deliver it,
/// and the command is dropped (the sending app is still told it went out).
///
/// [start] and [stop] open and close that socket, as the real receiver's do.
class _JellyfinServer implements RemoteControlReceiver {
  final StreamController<RemoteCommand> _commands =
      StreamController<RemoteCommand>.broadcast();
  bool _connected = false;

  /// Commands that arrived while no socket was open.
  int dropped = 0;

  /// Another Jellyfin app sends [command] to this player.
  void send(RemoteCommand command) {
    if (_connected) {
      _commands.add(command);
    } else {
      dropped++;
    }
  }

  @override
  Stream<RemoteCommand> get commands => _commands.stream;

  @override
  Future<void> start() async => _connected = true;

  @override
  Future<void> stop() async => _connected = false;

  @override
  Future<void> dispose() async {
    _connected = false;
    await _commands.close();
  }
}

const Track _first =
    Track(id: 'item-1', title: 'First', uri: 'jellyfin:item-1');
const Track _second =
    Track(id: 'item-2', title: 'Second', uri: 'jellyfin:item-2');

void main() {
  test(
      'a remote Pause sent while the next Jellyfin track loads still '
      'pauses it', () async {
    final _JellyfinServer server = _JellyfinServer();
    final FakePlaybackController engine = FakePlaybackController();
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        localPlaybackControllerProvider.overrideWithValue(engine),
        remoteControlReceiverProvider.overrideWithValue(server),
      ],
    );
    addTearDown(container.dispose);
    // What main() reads after startup.
    container.read(remoteControlServiceProvider);
    container.read(remoteControlActivatorProvider);

    engine.emit(const PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: _first,
      upNext: <Track>[_second],
    ));
    await pumpEventQueue();

    // Next from the Jellyfin app: every track change opens with the next
    // track loading, as the controller publishes it before it resolves.
    engine.emit(const PlaybackState(
      status: PlaybackStatus.loading,
      currentTrack: _second,
      previous: <Track>[_first],
      hasPrevious: true,
    ));
    await pumpEventQueue();

    // The listener changes their mind before the track has started.
    server.send(const RemotePause());
    await pumpEventQueue();

    expect(server.dropped, 0,
        reason: 'the control socket was closed while the track loaded, so '
            'the server had nowhere to deliver the Pause');
    expect(engine.pauseCount, 1);
  });
}
