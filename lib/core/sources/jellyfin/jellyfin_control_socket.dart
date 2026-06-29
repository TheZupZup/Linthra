import 'dart:async';
import 'dart:io';

/// A live control connection to a Jellyfin server's session WebSocket.
///
/// Abstracted behind this seam so the receiver's logic — parse, emit, keepalive,
/// reconnect — is unit-testable with a fake, while the real implementation is a
/// thin `dart:io` [WebSocket] (no extra package, so the committed lockfile is
/// untouched).
abstract interface class JellyfinControlSocket {
  /// Text frames from the server, each a raw JSON envelope the receiver decodes
  /// and maps. The stream completes (or errors) when the socket closes.
  Stream<String> get messages;

  /// Sends a text frame to the server (e.g. a `KeepAlive` reply).
  void send(String message);

  /// Closes the connection. Idempotent.
  Future<void> close();
}

/// Opens a [JellyfinControlSocket] to [url]. Injected into the receiver so tests
/// supply a fake; production passes [connectJellyfinControlSocket].
typedef JellyfinControlSocketConnector = Future<JellyfinControlSocket> Function(
  Uri url,
);

/// Production connector: a `dart:io` [WebSocket]. The [url] carries the access
/// token in its `ApiKey` query, so it must never be logged here.
Future<JellyfinControlSocket> connectJellyfinControlSocket(Uri url) async {
  final WebSocket socket = await WebSocket.connect(url.toString());
  return _WebSocketJellyfinControlSocket(socket);
}

class _WebSocketJellyfinControlSocket implements JellyfinControlSocket {
  _WebSocketJellyfinControlSocket(this._socket);

  final WebSocket _socket;

  @override
  Stream<String> get messages =>
      _socket.where((Object? event) => event is String).cast<String>();

  @override
  void send(String message) => _socket.add(message);

  @override
  Future<void> close() => _socket.close();
}
