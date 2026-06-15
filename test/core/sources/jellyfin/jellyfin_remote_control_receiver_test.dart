import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/services/remote_command.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_control_socket.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_remote_control_receiver.dart';

import 'fake_jellyfin_client.dart';

/// An in-memory [JellyfinControlSocket]: a test pushes server frames via [emit]
/// and reads back whatever the receiver [send]s.
class _FakeSocket implements JellyfinControlSocket {
  final StreamController<String> _incoming = StreamController<String>();
  final List<String> sent = <String>[];
  bool closed = false;

  @override
  Stream<String> get messages => _incoming.stream;

  @override
  void send(String message) => sent.add(message);

  @override
  Future<void> close() async {
    closed = true;
    if (!_incoming.isClosed) await _incoming.close();
  }

  void emit(String raw) => _incoming.add(raw);
}

const JellyfinSession _session = JellyfinSession(
  baseUrl: 'https://music.example.com',
  userId: 'user-1',
  accessToken: 'tok',
  deviceId: 'dev-1',
);

String _playstate(String command) => jsonEncode(<String, dynamic>{
      'MessageType': 'Playstate',
      'Data': <String, dynamic>{'Command': command},
    });

void main() {
  test('registers capabilities and connects on start', () async {
    final FakeJellyfinClient client = FakeJellyfinClient();
    final _FakeSocket socket = _FakeSocket();
    Uri? connectedTo;
    final JellyfinRemoteControlReceiver receiver = JellyfinRemoteControlReceiver(
      session: () => _session,
      client: () => client,
      connect: (Uri url) async {
        connectedTo = url;
        return socket;
      },
    );

    await receiver.start();
    await pumpEventQueue();

    expect(client.capabilitiesRegistered, 1);
    expect(connectedTo, isNotNull);
    expect(connectedTo!.scheme, 'wss');
    expect(connectedTo!.path, '/socket');

    await receiver.dispose();
  });

  test('emits a neutral command for a Playstate message', () async {
    final FakeJellyfinClient client = FakeJellyfinClient();
    final _FakeSocket socket = _FakeSocket();
    final JellyfinRemoteControlReceiver receiver = JellyfinRemoteControlReceiver(
      session: () => _session,
      client: () => client,
      connect: (Uri _) async => socket,
    );
    final List<RemoteCommand> received = <RemoteCommand>[];
    final StreamSubscription<RemoteCommand> sub =
        receiver.commands.listen(received.add);

    await receiver.start();
    await pumpEventQueue();
    socket.emit(_playstate('Pause'));
    await pumpEventQueue();

    expect(received, <RemoteCommand>[const RemotePause()]);

    await sub.cancel();
    await receiver.dispose();
  });

  test('answers ForceKeepAlive with a KeepAlive frame', () async {
    final FakeJellyfinClient client = FakeJellyfinClient();
    final _FakeSocket socket = _FakeSocket();
    final JellyfinRemoteControlReceiver receiver = JellyfinRemoteControlReceiver(
      session: () => _session,
      client: () => client,
      connect: (Uri _) async => socket,
    );

    await receiver.start();
    await pumpEventQueue();
    socket.emit(jsonEncode(<String, dynamic>{
      'MessageType': 'ForceKeepAlive',
      'Data': 30,
    }));
    await pumpEventQueue();

    expect(socket.sent, isNotEmpty);
    expect(socket.sent.first, contains('KeepAlive'));

    await receiver.dispose();
  });

  test('does not connect when signed out', () async {
    final FakeJellyfinClient client = FakeJellyfinClient();
    int connectCalls = 0;
    final JellyfinRemoteControlReceiver receiver = JellyfinRemoteControlReceiver(
      session: () => null,
      client: () => client,
      connect: (Uri _) async {
        connectCalls++;
        return _FakeSocket();
      },
    );

    await receiver.start();
    await pumpEventQueue();

    expect(connectCalls, 0);
    expect(client.capabilitiesRegistered, 0);

    await receiver.dispose();
  });

  test('stop disconnects the socket', () async {
    final FakeJellyfinClient client = FakeJellyfinClient();
    final _FakeSocket socket = _FakeSocket();
    final JellyfinRemoteControlReceiver receiver = JellyfinRemoteControlReceiver(
      session: () => _session,
      client: () => client,
      connect: (Uri _) async => socket,
    );

    await receiver.start();
    await pumpEventQueue();
    await receiver.stop();

    expect(socket.closed, isTrue);

    await receiver.dispose();
  });
}
