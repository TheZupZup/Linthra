import 'dart:async';

import 'package:dbus/dbus.dart';

import 'background_permission.dart';
import 'portal_connectivity_service.dart' show SessionBusConnector;

/// [BackgroundPermissionRequester] over the desktop's Background portal
/// (`org.freedesktop.portal.Background.RequestBackground`).
///
/// What the portal does with the question (xdg-desktop-portal 1.18,
/// `src/background.c`):
///
///  * an app with no stored `background` permission is allowed, and "yes" is
///    stored for it without a prompt, so the background monitor leaves it
///    alone from then on;
///  * "yes" is allowed and "no" is refused, again without a prompt;
///  * "ask" shows the desktop's own dialog with [reason] in it.
///
/// The answer comes back as the `Response` signal of a request object under
/// the caller's own path namespace (its unique name, with the `handle_token`
/// option as the last element). Each question gets a connection of its own,
/// so any answer under that namespace is the one: it is listened for before
/// the call goes out and can't be missed, wherever the portal puts it.
///
/// A desktop whose portal has no Background backend (the interface isn't
/// there) has no background monitor either, so that reads as allowed.
/// Anything else that keeps the question from being answered (no session bus,
/// no portal at all, no reply) reads as [BackgroundPermission.unknown].
///
/// Only meaningful inside the Flatpak: outside it nothing kills an app for
/// having no window, and the app is wired to this only there.
class PortalBackgroundPermission implements BackgroundPermissionRequester {
  /// [connect] opens the session bus; null when there is none to ask.
  PortalBackgroundPermission({
    required SessionBusConnector? connect,
    Duration callTimeout = const Duration(seconds: 10),
    Duration answerTimeout = const Duration(minutes: 2),
  })  : _connect = connect,
        _callTimeout = callTimeout,
        _answerTimeout = answerTimeout;

  /// Shown by a desktop that asks the user (the permission set to "ask").
  /// The portal refuses reasons over 256 characters.
  static const String reason = 'Keep playing music with the window closed';

  static const String _portalName = 'org.freedesktop.portal.Desktop';
  static const String _interface = 'org.freedesktop.portal.Background';
  static const String _requestInterface = 'org.freedesktop.portal.Request';
  static final DBusObjectPath _portalPath =
      DBusObjectPath('/org/freedesktop/portal/desktop');

  final SessionBusConnector? _connect;

  /// How long the call itself may take, before the answer.
  final Duration _callTimeout;

  /// How long to wait for the answer. A desktop that asks the user waits on
  /// them, so this is generous; past it the answer reads as unknown.
  final Duration _answerTimeout;

  /// The question already out, shared by everyone who asks meanwhile.
  Future<BackgroundPermission>? _asking;

  int _requests = 0;

  @override
  Future<BackgroundPermission> request() {
    final Future<BackgroundPermission>? asking = _asking;
    if (asking != null) return asking;
    final Future<BackgroundPermission> question = _askOnce();
    _asking = question;
    return question;
  }

  Future<BackgroundPermission> _askOnce() async {
    try {
      return await _ask();
    } finally {
      _asking = null;
    }
  }

  Future<BackgroundPermission> _ask() async {
    final SessionBusConnector? connect = _connect;
    if (connect == null) return BackgroundPermission.unknown;
    DBusClient? client;
    StreamSubscription<DBusSignal>? subscription;
    try {
      client = connect();
      final DBusClient bus = client;
      // Connected once this returns, so the unique name the request path is
      // built from is known. GetId rather than a ping: inside the Flatpak the
      // session bus goes through xdg-dbus-proxy, which passes only a short
      // list of the bus's own methods (Hello, AddMatch, RemoveMatch, GetId,
      // ...) and refuses org.freedesktop.DBus.Peer.Ping to the bus.
      await bus.getId().timeout(_callTimeout);

      final String token = 'linthra_background_${++_requests}';
      final Completer<BackgroundPermission> answer =
          Completer<BackgroundPermission>();
      subscription = DBusSignalStream(
        bus,
        interface: _requestInterface,
        name: 'Response',
        pathNamespace: _requestNamespace(bus.uniqueName),
      ).listen((DBusSignal signal) {
        if (!answer.isCompleted) answer.complete(_read(signal.values));
      });
      // The bus handles one connection's messages in order: once this round
      // trip is back, the match rule for the answer is in place.
      await bus.getId().timeout(_callTimeout);

      await bus
          .callMethod(
            destination: _portalName,
            path: _portalPath,
            interface: _interface,
            name: 'RequestBackground',
            values: <DBusValue>[
              // No parent window: the question isn't tied to one, and the
              // window may be about to go.
              const DBusString(''),
              DBusDict.stringVariant(<String, DBusValue>{
                'handle_token': DBusString(token),
                'reason': const DBusString(reason),
                'autostart': const DBusBoolean(false),
                'dbus-activatable': const DBusBoolean(false),
              }),
            ],
            replySignature: DBusSignature('o'),
          )
          .timeout(_callTimeout);
      return await answer.future.timeout(
        _answerTimeout,
        onTimeout: () => BackgroundPermission.unknown,
      );
    } on DBusUnknownInterfaceException {
      // No Background backend, so no background monitor either.
      return BackgroundPermission.allowed;
    } on DBusUnknownMethodException {
      return BackgroundPermission.allowed;
    } catch (_) {
      return BackgroundPermission.unknown;
    } finally {
      await subscription?.cancel();
      await client?.close();
    }
  }

  /// Where the portal puts requests from [uniqueName]: under the sender's
  /// unique name without its leading ':' and with '.' as '_'.
  static DBusObjectPath _requestNamespace(String uniqueName) {
    final String sender = uniqueName.replaceFirst(':', '').replaceAll('.', '_');
    return DBusObjectPath('/org/freedesktop/portal/desktop/request/$sender');
  }

  /// The `Response` signal's `(u response, a{sv} results)`: 0 with
  /// `background` true is allowed; 1 (cancelled) is what the portal sends
  /// when it isn't, along with `background` false; anything else (2, an
  /// error on its side) says nothing either way.
  static BackgroundPermission _read(List<DBusValue> values) {
    if (values.length < 2) return BackgroundPermission.unknown;
    final DBusValue code = values[0];
    final DBusValue results = values[1];
    if (code is! DBusUint32) return BackgroundPermission.unknown;
    bool? background;
    if (results is DBusDict) {
      for (final MapEntry<DBusValue, DBusValue> entry
          in results.children.entries) {
        final DBusValue key = entry.key;
        final DBusValue value = entry.value;
        if (key is DBusString &&
            key.value == 'background' &&
            value is DBusVariant &&
            value.value is DBusBoolean) {
          background = (value.value as DBusBoolean).value;
        }
      }
    }
    switch (code.value) {
      case 0:
        return background == false
            ? BackgroundPermission.denied
            : BackgroundPermission.allowed;
      case 1:
        return BackgroundPermission.denied;
      default:
        return BackgroundPermission.unknown;
    }
  }
}
