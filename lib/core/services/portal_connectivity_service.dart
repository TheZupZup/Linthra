import 'dart:async';
import 'dart:io' show SocketException;

import 'package:dbus/dbus.dart';

import 'connectivity_service.dart';

/// Opens the session bus connection [PortalConnectivityService] talks over.
typedef SessionBusConnector = DBusClient Function();

/// Linux [ConnectivityService], read from the desktop's network monitor portal
/// (`org.freedesktop.portal.NetworkMonitor`) on the session bus.
///
/// The portal is how a Flatpak app is meant to ask about the network, and it
/// answers outside the sandbox too wherever xdg-desktop-portal runs. Talking to
/// it needs no permission beyond the session bus every Flatpak app already
/// has: portals are always reachable through the sandbox's bus filter.
///
/// Only metering is read. The portal's own "available" flag means "has a
/// default route", and a music server on a network without one (a NAS cabled
/// straight to the laptop) is still reachable, so its absence is never taken
/// as offline: a stream or download tried while really offline fails on its
/// own and says so. Anything the portal can't answer (no portal, no session
/// bus, a reply that never comes) is [NetworkStatus.unknown], which the
/// download policy treats conservatively, as before.
class PortalConnectivityService implements ConnectivityService {
  /// [connect] opens the session bus; null when there is none to ask, and
  /// then everything reads as unknown and no change is ever reported.
  PortalConnectivityService({
    required SessionBusConnector? connect,
    Duration callTimeout = const Duration(seconds: 5),
    Duration quietAfterNoAnswer = const Duration(minutes: 1),
    DateTime Function()? now,
  })  : _connect = connect,
        _callTimeout = callTimeout,
        _quietAfterNoAnswer = quietAfterNoAnswer,
        _now = now ?? DateTime.now;

  static const String _portalName = 'org.freedesktop.portal.Desktop';
  static const String _interface = 'org.freedesktop.portal.NetworkMonitor';
  static final DBusObjectPath _portalPath =
      DBusObjectPath('/org/freedesktop/portal/desktop');

  final SessionBusConnector? _connect;

  /// How long a portal call may take. Long enough for the bus to start the
  /// portal on first use; a call that takes longer reads as unknown.
  final Duration _callTimeout;

  /// How long the portal is left alone after a call it never answered.
  /// Playback asks before every remote stream, and a portal stuck on an
  /// unresponsive backend would otherwise hold each one for [_callTimeout].
  final Duration _quietAfterNoAnswer;

  final DateTime Function() _now;

  /// The session bus, once it has answered on the connection: shared by the
  /// questions and the change signal, and opened on first use.
  Future<DBusClient>? _bus;

  /// The connection [_bus] opened, closed on [dispose].
  DBusClient? _client;
  bool _closed = false;

  /// The question already on the bus, shared by everyone who asks meanwhile.
  Future<NetworkStatus>? _asking;

  /// Until when the portal is not asked, after one that never answered.
  DateTime? _quietUntil;

  /// Ends the quiet period, so the portal is asked again.
  Timer? _quietTimer;

  /// Has the change stream read the status again with no signal from the
  /// portal: when a quiet period starts (everyone is told unknown from then
  /// on) and when it ends (the portal can be asked again).
  final StreamController<void> _askAgain = StreamController<void>.broadcast();

  late final Stream<NetworkStatus> _changes =
      _portalChanges().distinct().asBroadcastStream();

  @override
  Stream<NetworkStatus> get statusStream => _changes;

  @override
  Future<NetworkStatus> currentStatus() {
    if (_closed || _connect == null) {
      return Future<NetworkStatus>.value(NetworkStatus.unknown);
    }
    final DateTime? quietUntil = _quietUntil;
    if (quietUntil != null && _now().isBefore(quietUntil)) {
      return Future<NetworkStatus>.value(NetworkStatus.unknown);
    }
    return _asking ??= _ask().whenComplete(() => _asking = null);
  }

  Future<NetworkStatus> _ask() async {
    try {
      final DBusMethodSuccessResponse reply =
          await _getMetered().timeout(_callTimeout);
      return reply.returnValues.single.asBoolean()
          ? NetworkStatus.mobile
          : NetworkStatus.wifi;
    } catch (error) {
      if (!_portalCannotAnswer(error)) rethrow;
      if (error is TimeoutException && !_closed) {
        _quietUntil = _now().add(_quietAfterNoAnswer);
        // A download held on this unknown is only asked again on a change,
        // and the network may never change: once the portal can be asked
        // again, the change stream asks it and reports the answer.
        _quietTimer?.cancel();
        _quietTimer = Timer(_quietAfterNoAnswer, () {
          _quietUntil = null;
          _askAgain.add(null);
        });
        _askAgain.add(null);
      }
      return NetworkStatus.unknown;
    }
  }

  Future<DBusMethodSuccessResponse> _getMetered() async =>
      _portalOn(await _openBus()).callMethod(
        _interface,
        'GetMetered',
        const <DBusValue>[],
        replySignature: DBusSignature('b'),
      );

  DBusRemoteObject _portalOn(DBusClient client) =>
      DBusRemoteObject(client, name: _portalName, path: _portalPath);

  /// The session bus, opened on first use and counted as open once the bus
  /// has answered on it. The dbus package never settles a connection whose
  /// socket failed to open, so anything else sent on one would wait forever:
  /// one that couldn't be opened is let go, and the next use tries again.
  Future<DBusClient> _openBus() {
    final Future<DBusClient>? open = _bus;
    if (open != null) return open;
    final Future<DBusClient> opening = _bus = _reachBus();
    opening.then<void>((_) {}, onError: (Object _) {
      if (identical(_bus, opening)) _bus = null;
    });
    return opening;
  }

  Future<DBusClient> _reachBus() async {
    final DBusClient client = _client = _connect!();
    // GetId: one of the few bus calls a Flatpak's bus filter lets through
    // (it refuses Peer.Ping).
    await client.getId();
    return client;
  }

  /// Reads the status again each time the portal says the network changed.
  Stream<NetworkStatus> _portalChanges() async* {
    if (_closed || _connect == null) return;
    final DBusClient client;
    try {
      // Only once the bus has answered: listening for a signal starts calls
      // the dbus package doesn't wait for, which on a bus that can't be
      // reached would fail with nobody to hear it. A bus that never answers
      // just means no change is heard.
      client = await _openBus();
    } catch (error) {
      if (!_portalCannotAnswer(error)) rethrow;
      // No bus to listen on: no change will ever be heard.
      return;
    }
    if (_closed) return;
    final Stream<DBusSignal> changed = DBusRemoteObjectSignalStream(
      object: _portalOn(client),
      interface: _interface,
      name: 'changed',
    );
    final StreamController<void> asks = StreamController<void>();
    final StreamSubscription<DBusSignal> signals = changed.listen(
      (DBusSignal _) => asks.add(null),
      onError: asks.addError,
      onDone: asks.close,
    );
    final StreamSubscription<void> quiet = _askAgain.stream.listen(asks.add);
    try {
      await for (final void _ in asks.stream) {
        yield await currentStatus();
      }
    } finally {
      await quiet.cancel();
      await signals.cancel();
    }
  }

  /// What failing to ask the portal looks like: no portal on this desktop, or
  /// one without this interface; a reply of the wrong shape; no reply in time
  /// (a bus that refused the login never answers at all); no session bus; the
  /// connection closed under the call; or a session bus address the dbus
  /// package can't read, or can't use, which it throws as a plain string.
  static bool _portalCannotAnswer(Object error) =>
      error is DBusMethodResponseException ||
      error is DBusReplySignatureException ||
      error is DBusClosedException ||
      error is TimeoutException ||
      error is SocketException ||
      error is FormatException ||
      error is String;

  /// Lets go of the session bus connection. Safe to call more than once.
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _quietTimer?.cancel();
    _quietTimer = null;
    unawaited(_askAgain.close());
    final DBusClient? client = _client;
    _client = null;
    _bus = null;
    await client?.close();
  }
}
