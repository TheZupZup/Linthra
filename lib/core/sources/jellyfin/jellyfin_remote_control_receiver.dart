import 'dart:async';
import 'dart:convert';

import '../../models/jellyfin_session.dart';
import '../../services/remote_command.dart';
import '../../services/remote_control_receiver.dart';
import 'jellyfin_client.dart';
import 'jellyfin_control_socket.dart';
import 'jellyfin_endpoints.dart';
import 'jellyfin_remote_command.dart';

/// Receives remote playback commands from a Jellyfin server over its session
/// control WebSocket, surfaced as neutral [RemoteCommand]s.
///
/// Jellyfin remote control is **outbound**: this client connects out to the
/// server's `/socket`, registers its session capabilities (audio + media
/// control), and the server then pushes `Playstate` commands down that socket
/// when another Jellyfin app drives this player. Being outbound, it works
/// behind NAT with no inbound server — unlike Plex's Companion protocol.
///
/// Resilience & best-effort: [start] connects (and reconnects after a drop,
/// with a fixed delay) while a session is signed in; the server's
/// `ForceKeepAlive` is answered with periodic `KeepAlive`s. A transport failure
/// only schedules a reconnect — it never throws out of [commands] or disturbs
/// playback. [stop] disconnects without ending the command stream (a later
/// [start] resumes); [dispose] closes everything.
///
/// Token safety: the access token rides in the WebSocket URL's `api_key` query
/// (like the audio stream URL) and the capability POST's `Authorization`
/// header; the URL is never logged, and nothing here is persisted.
class JellyfinRemoteControlReceiver implements RemoteControlReceiver {
  JellyfinRemoteControlReceiver({
    required JellyfinSession? Function() session,
    required JellyfinClient Function() client,
    JellyfinControlSocketConnector connect = connectJellyfinControlSocket,
    Duration retryDelay = const Duration(seconds: 15),
  })  : _session = session,
        _client = client,
        _connect = connect,
        _retryDelay = retryDelay;

  final JellyfinSession? Function() _session;
  final JellyfinClient Function() _client;
  final JellyfinControlSocketConnector _connect;
  final Duration _retryDelay;

  final StreamController<RemoteCommand> _commands =
      StreamController<RemoteCommand>.broadcast();

  JellyfinControlSocket? _socket;
  StreamSubscription<String>? _messages;
  Timer? _keepAlive;
  Timer? _retry;
  bool _running = false;
  bool _disposed = false;

  @override
  Stream<RemoteCommand> get commands => _commands.stream;

  @override
  Future<void> start() async {
    if (_disposed || _running) return;
    _running = true;
    await _open();
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _retry?.cancel();
    _retry = null;
    await _teardownSocket();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _running = false;
    _retry?.cancel();
    _retry = null;
    await _teardownSocket();
    await _commands.close();
  }

  Future<void> _open() async {
    if (_disposed || !_running) return;
    final JellyfinSession? session = _session();
    if (session == null) {
      // Signed out: nothing to connect to. A later start (after sign-in) tries
      // again; don't busy-retry here.
      return;
    }

    // Best-effort capability registration so other Jellyfin apps list this
    // player as controllable. A failure here must not stop us listening.
    try {
      await _client().registerRemoteControlCapabilities(session);
    } catch (_) {
      // ignore — still try to receive commands.
    }
    if (_disposed || !_running) return;

    try {
      final Uri url = JellyfinEndpoints.controlSocket(
        session.baseUrl,
        accessToken: session.accessToken,
        deviceId: session.deviceId,
      );
      final JellyfinControlSocket socket = await _connect(url);
      if (_disposed || !_running) {
        await socket.close();
        return;
      }
      _socket = socket;
      _messages = socket.messages.listen(
        _onMessage,
        onError: (Object _) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
        cancelOnError: true,
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _onMessage(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;

    final Object? type = decoded['MessageType'];
    if (type is String && type.toLowerCase() == 'forcekeepalive') {
      _sendKeepAlive();
      _scheduleKeepAlive(decoded['Data']);
      return;
    }

    final RemoteCommand? command = JellyfinRemoteCommand.fromMessage(decoded);
    if (command != null && !_commands.isClosed) {
      _commands.add(command);
    }
  }

  void _scheduleKeepAlive(Object? data) {
    _keepAlive?.cancel();
    // ForceKeepAlive carries the server's timeout (seconds); reply at half that
    // to stay inside the window. Fall back to 60s, clamped to a sane range.
    final int timeout = data is int && data > 1 ? data : 60;
    int every = timeout ~/ 2;
    if (every < 5) every = 5;
    if (every > 60) every = 60;
    _keepAlive = Timer.periodic(
      Duration(seconds: every),
      (_) => _sendKeepAlive(),
    );
  }

  void _sendKeepAlive() {
    final JellyfinControlSocket? socket = _socket;
    if (socket == null) return;
    try {
      socket.send(jsonEncode(<String, Object?>{
        'MessageType': 'KeepAlive',
        'Data': '',
      }));
    } catch (_) {
      // A dead socket surfaces via onError/onDone, which reconnects.
    }
  }

  void _scheduleReconnect() {
    if (_disposed || !_running) return;
    unawaited(_teardownSocket());
    _retry?.cancel();
    _retry = Timer(_retryDelay, () => unawaited(_open()));
  }

  Future<void> _teardownSocket() async {
    _keepAlive?.cancel();
    _keepAlive = null;
    final StreamSubscription<String>? messages = _messages;
    _messages = null;
    final JellyfinControlSocket? socket = _socket;
    _socket = null;
    await messages?.cancel();
    await socket?.close();
  }
}
