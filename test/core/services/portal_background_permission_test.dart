import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/background_permission.dart';
import 'package:linthra/core/services/portal_background_permission.dart';

const String _interface = 'org.freedesktop.portal.Background';

/// The `background` permission xdg-desktop-portal keeps per app.
enum _Stored { unset, yes, no, ask }

/// The desktop's Background portal, answering the way xdg-desktop-portal 1.18
/// does (`src/background.c`), on a bus of the test's own: the requester under
/// test talks real D-Bus to it.
///
///  * unset is allowed with no prompt, and "yes" is stored;
///  * yes is allowed, no is refused, both with no prompt;
///  * ask shows the desktop's dialog, answered here by [dialogAllows].
///
/// The answer is the `Response` signal of the request object, at the path
/// built from the caller's unique name and its `handle_token`.
class _BackgroundPortal extends DBusObject {
  _BackgroundPortal(this.bus)
      : super(DBusObjectPath('/org/freedesktop/portal/desktop'));

  final DBusClient bus;

  _Stored stored = _Stored.unset;
  bool dialogAllows = true;
  int dialogs = 0;

  /// No Background backend: xdg-desktop-portal then doesn't export the
  /// interface at all.
  bool hasBackend = true;

  /// Answers at its own path instead of the one handle_token asks for, as a
  /// portal from before handle_token did.
  bool ignoresHandleToken = false;

  /// Never sends the answer.
  bool silent = false;

  final List<Map<String, DBusValue>> requests = <Map<String, DBusValue>>[];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != _interface || !hasBackend) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    if (methodCall.name != 'RequestBackground') {
      return DBusMethodErrorResponse.unknownMethod();
    }
    final Map<String, DBusValue> options = <String, DBusValue>{
      for (final MapEntry<DBusValue, DBusValue> entry
          in (methodCall.values[1] as DBusDict).children.entries)
        (entry.key as DBusString).value: (entry.value as DBusVariant).value,
    };
    requests.add(options);
    final String token = ignoresHandleToken
        ? 'portal${requests.length}'
        : (options['handle_token']! as DBusString).value;
    final String sender =
        methodCall.sender!.replaceFirst(':', '').replaceAll('.', '_');
    final DBusObjectPath handle = DBusObjectPath(
        '/org/freedesktop/portal/desktop/request/$sender/$token');

    final bool allowed;
    switch (stored) {
      case _Stored.ask:
        dialogs++;
        allowed = dialogAllows;
      case _Stored.unset:
        allowed = true;
        stored = _Stored.yes;
      case _Stored.yes:
        allowed = true;
      case _Stored.no:
        allowed = false;
    }
    if (!silent) {
      // After the reply, as the portal does: the request is answered from
      // another thread once the call has returned its handle.
      Timer.run(() => unawaited(bus.emitSignal(
            destination: methodCall.sender,
            path: handle,
            interface: 'org.freedesktop.portal.Request',
            name: 'Response',
            values: <DBusValue>[
              DBusUint32(allowed ? 0 : 1),
              DBusDict.stringVariant(<String, DBusValue>{
                'background': DBusBoolean(allowed),
                'autostart': const DBusBoolean(false),
              }),
            ],
          )));
    }
    return DBusMethodSuccessResponse(<DBusValue>[handle]);
  }
}

/// The bus's own methods xdg-dbus-proxy passes from inside a Flatpak
/// (`flatpak-proxy.c`, `get_dbus_method_handler`): calls to
/// `org.freedesktop.DBus` on any other interface, `org.freedesktop.DBus.Peer`
/// included, are refused with AccessDenied, and introspection is the one
/// exception. The bus-name methods are validated against the app's policy.
const Set<String> _proxyPassesBusMethods = <String>{
  'Hello',
  'AddMatch',
  'RemoveMatch',
  'GetId',
  'RequestName',
  'ReleaseName',
  'ListQueuedOwners',
  'NameHasOwner',
  'GetNameOwner',
  'StartServiceByName',
  'ListNames',
  'ListActivatableNames',
};

/// A [DBusClient] that records every method call it makes, so a test can hold
/// the requester to what the sandbox's bus proxy allows.
class _RecordingBus extends DBusClient {
  _RecordingBus(super.address);

  final List<String> busCalls = <String>[];

  @override
  Future<DBusMethodSuccessResponse> callMethod({
    String? destination,
    required DBusObjectPath path,
    String? interface,
    required String name,
    Iterable<DBusValue> values = const <DBusValue>[],
    DBusSignature? replySignature,
    bool noReplyExpected = false,
    bool noAutoStart = false,
    bool allowInteractiveAuthorization = false,
  }) {
    if (destination == 'org.freedesktop.DBus') {
      busCalls.add('$interface.$name');
    }
    return super.callMethod(
      destination: destination,
      path: path,
      interface: interface,
      name: name,
      values: values,
      replySignature: replySignature,
      noReplyExpected: noReplyExpected,
      noAutoStart: noAutoStart,
      allowInteractiveAuthorization: allowInteractiveAuthorization,
    );
  }
}

void main() {
  late DBusServer server;
  late DBusAddress address;
  late DBusClient portalSide;
  late _BackgroundPortal portal;

  setUp(() async {
    server = DBusServer();
    address =
        await server.listenAddress(DBusAddress.unix(dir: Directory.systemTemp));
    portalSide = DBusClient(address);
    portal = _BackgroundPortal(portalSide);
  });

  tearDown(() async {
    await portalSide.close();
    await server.close();
  });

  Future<void> startPortal() async {
    await portalSide.requestName('org.freedesktop.portal.Desktop');
    await portalSide.registerObject(portal);
  }

  PortalBackgroundPermission requester({
    Duration answerTimeout = const Duration(seconds: 5),
  }) =>
      PortalBackgroundPermission(
        connect: () => DBusClient(address),
        callTimeout: const Duration(seconds: 2),
        answerTimeout: answerTimeout,
      );

  test(
      'an app the desktop has no answer stored for is allowed, and "yes" '
      'is stored with no prompt', () async {
    await startPortal();

    expect(await requester().request(), BackgroundPermission.allowed);
    expect(portal.stored, _Stored.yes);
    expect(portal.dialogs, 0);
  });

  test('asks without autostart, with a reason the portal accepts', () async {
    await startPortal();

    await requester().request();

    final Map<String, DBusValue> options = portal.requests.single;
    expect(options['autostart'], const DBusBoolean(false));
    expect(options['dbus-activatable'], const DBusBoolean(false));
    final String reason = (options['reason']! as DBusString).value;
    expect(reason, PortalBackgroundPermission.reason);
    // xdg-desktop-portal refuses a reason longer than 256 characters.
    expect(reason.length, lessThanOrEqualTo(256));
    expect(options['handle_token'], isA<DBusString>());
  });

  test('a stored "no" is refused', () async {
    portal.stored = _Stored.no;
    await startPortal();

    expect(await requester().request(), BackgroundPermission.denied);
  });

  test('"ask" is up to the desktop\'s dialog', () async {
    portal.stored = _Stored.ask;
    await startPortal();

    expect(await requester().request(), BackgroundPermission.allowed);
    portal.dialogAllows = false;
    expect(await requester().request(), BackgroundPermission.denied);
    expect(portal.dialogs, 2);
  });

  test('a portal with no Background backend reads as allowed', () async {
    // No backend, no background monitor: nothing would kill the app.
    portal.hasBackend = false;
    await startPortal();

    expect(await requester().request(), BackgroundPermission.allowed);
  });

  test('no portal at all reads as unknown', () async {
    // Nothing owns the portal's name on this bus.
    expect(await requester().request(), BackgroundPermission.unknown);
  });

  test('no session bus reads as unknown', () async {
    expect(
      await PortalBackgroundPermission(connect: null).request(),
      BackgroundPermission.unknown,
    );
  });

  test('an answer that never comes reads as unknown in time', () async {
    portal.silent = true;
    await startPortal();

    expect(
      await requester(answerTimeout: const Duration(milliseconds: 300))
          .request(),
      BackgroundPermission.unknown,
    );
  });

  test('a portal that answers somewhere else is still heard', () async {
    portal
      ..ignoresHandleToken = true
      ..stored = _Stored.no;
    await startPortal();

    expect(await requester().request(), BackgroundPermission.denied);
  });

  test('calls nothing on the bus that the Flatpak\'s bus proxy refuses',
      () async {
    await startPortal();
    final List<_RecordingBus> buses = <_RecordingBus>[];
    final PortalBackgroundPermission sandboxed = PortalBackgroundPermission(
      connect: () {
        final _RecordingBus bus = _RecordingBus(address);
        buses.add(bus);
        return bus;
      },
    );

    expect(await sandboxed.request(), BackgroundPermission.allowed);

    final List<String> calls = buses.single.busCalls;
    expect(calls, isNotEmpty);
    for (final String call in calls) {
      expect(call, startsWith('org.freedesktop.DBus.'));
      expect(
        _proxyPassesBusMethods,
        contains(call.substring('org.freedesktop.DBus.'.length)),
        reason: '$call would be refused inside the Flatpak',
      );
    }
  });

  test('askers at once share one question', () async {
    await startPortal();
    final PortalBackgroundPermission shared = requester();

    final List<BackgroundPermission> answers =
        await Future.wait(<Future<BackgroundPermission>>[
      shared.request(),
      shared.request(),
    ]);

    expect(answers, <BackgroundPermission>[
      BackgroundPermission.allowed,
      BackgroundPermission.allowed,
    ]);
    expect(portal.requests, hasLength(1));
    // And a later question is put again.
    await shared.request();
    expect(portal.requests, hasLength(2));
  });
}
