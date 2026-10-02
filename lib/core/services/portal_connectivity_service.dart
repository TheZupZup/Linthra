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
  PortalConnectivityService({
    SessionBusConnector? connect,
    Duration callTimeout = const Duration(seconds: 5),
    Duration quietAfterNoAnswer = const Duration(minutes: 1),
    DateTime Function()? now,
  })  : _connect = connect ?? DBusClient.session,
        _callTimeout = callTimeout,
        _quietAfterNoAnswer = quietAfterNoAnswer,
        _now = now ?? DateTime.now;

  static const String _portalName = 'org.freedesktop.portal.Desktop';
  static const String _interface = 'org.freedesktop.portal.NetworkMonitor';
  static final DBusObjectPath _portalPath =
      DBusObjectPath('/org/freedesktop/portal/desktop');

  final SessionBusConnector _connect;

  /// How long a portal call may take. Long enough for the bus to start the
  /// portal on first use; a call that takes longer reads as unknown.
  final Duration _callTimeout;

  /// How long the portal is left alone after a call it never answered.
  /// Playback asks before every remote stream, and a portal stuck on an
  /// unresponsive backend would otherwise hold each one for [_callTimeout].
  final Duration _quietAfterNoAnswer;

  final DateTime Function() _now;

  DBusClient? _client;
  bool _closed = false;

  /// The question already on the bus, shared by everyone who asks meanwhile.
  Future<NetworkStatus>? _asking;

  /// Until when the portal is not asked, after one that never answered.
  DateTime? _quietUntil;

  DBusRemoteObject get _portal => DBusRemoteObject(
        _client ??= _connect(),
        name: _portalName,
        path: _portalPath,
      );

  late final Stream<NetworkStatus> _changes =
      _portalChanges().distinct().asBroadcastStream();

  @override
  Stream<NetworkStatus> get statusStream => _changes;

  @override
  Future<NetworkStatus> currentStatus() {
    if (_closed) return Future<NetworkStatus>.value(NetworkStatus.unknown);
    final DateTime? quietUntil = _quietUntil;
    if (quietUntil != null && _now().isBefore(quietUntil)) {
      return Future<NetworkStatus>.value(NetworkStatus.unknown);
    }
    return _asking ??= _ask().whenComplete(() => _asking = null);
  }

  Future<NetworkStatus> _ask() async {
    try {
      final DBusMethodSuccessResponse reply = await _portal
          .callMethod(
            _interface,
            'GetMetered',
            const <DBusValue>[],
            replySignature: DBusSignature('b'),
          )
          .timeout(_callTimeout);
      return reply.returnValues.single.asBoolean()
          ? NetworkStatus.mobile
          : NetworkStatus.wifi;
    } catch (error) {
      if (!_portalCannotAnswer(error)) rethrow;
      if (error is TimeoutException) {
        _quietUntil = _now().add(_quietAfterNoAnswer);
      }
      return NetworkStatus.unknown;
    }
  }

  /// Reads the status again each time the portal says the network changed.
  Stream<NetworkStatus> _portalChanges() async* {
    if (_closed) return;
    final Stream<DBusSignal> changed = DBusRemoteObjectSignalStream(
      object: _portal,
      interface: _interface,
      name: 'changed',
      signature: DBusSignature(''),
    );
    try {
      await for (final DBusSignal _ in changed) {
        yield await currentStatus();
      }
    } catch (error) {
      if (!_portalCannotAnswer(error)) rethrow;
      // Nothing to listen to: no change will ever be heard.
      yield NetworkStatus.unknown;
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
    final DBusClient? client = _client;
    _client = null;
    await client?.close();
  }
}
