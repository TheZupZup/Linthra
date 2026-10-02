import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/core/services/portal_connectivity_service.dart';

const String _interface = 'org.freedesktop.portal.NetworkMonitor';

/// The desktop's network monitor portal, as xdg-desktop-portal exports it
/// (data/org.freedesktop.portal.NetworkMonitor.xml), on a bus of the test's
/// own: the service under test talks real D-Bus to it.
class _NetworkMonitorPortal extends DBusObject {
  _NetworkMonitorPortal()
      : super(DBusObjectPath('/org/freedesktop/portal/desktop'));

  bool metered = false;
  int calls = 0;

  /// Holds every reply while set, the way a portal still starting up does.
  Completer<void>? hold;

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != _interface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    if (methodCall.name == 'GetMetered') calls++;
    final Completer<void>? pending = hold;
    if (pending != null) await pending.future;
    switch (methodCall.name) {
      case 'GetMetered':
        return DBusMethodSuccessResponse(<DBusValue>[DBusBoolean(metered)]);
      case 'GetAvailable':
        return DBusMethodSuccessResponse(<DBusValue>[const DBusBoolean(true)]);
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
  }

  /// The network changed: the portal says so, with no arguments.
  Future<void> change({required bool metered}) async {
    this.metered = metered;
    await emitSignal(_interface, 'changed');
  }
}

void main() {
  late DBusServer server;
  late DBusAddress address;
  late DBusClient portalSide;
  late _NetworkMonitorPortal portal;
  late PortalConnectivityService service;

  Future<void> startPortal() async {
    portalSide = DBusClient(address);
    await portalSide.requestName('org.freedesktop.portal.Desktop');
    await portalSide.registerObject(portal);
  }

  setUp(() async {
    server = DBusServer();
    address =
        await server.listenAddress(DBusAddress.unix(dir: Directory.systemTemp));
    portal = _NetworkMonitorPortal();
    service = PortalConnectivityService(
      connect: () => DBusClient(address),
      callTimeout: const Duration(seconds: 2),
    );
  });

  tearDown(() async {
    await service.dispose();
    await portalSide.close();
    await server.close();
  });

  test('an unmetered network reads as one downloads may use', () async {
    await startPortal();

    expect(await service.currentStatus(), NetworkStatus.wifi);
  });

  test('a metered network reads as metered', () async {
    portal.metered = true;
    await startPortal();

    expect(await service.currentStatus(), NetworkStatus.mobile);
  });

  test('a desktop with no portal reads as unknown, as before', () async {
    // Nothing owns the portal's name on this bus.
    portalSide = DBusClient(address);

    expect(await service.currentStatus(), NetworkStatus.unknown);
  });

  test('a portal that never answers reads as unknown in time', () async {
    service = PortalConnectivityService(
      connect: () => DBusClient(address),
      callTimeout: const Duration(milliseconds: 200),
    );
    portal.hold = Completer<void>();
    await startPortal();

    expect(await service.currentStatus(), NetworkStatus.unknown);
    portal.hold!.complete();
  });

  test('after a call it never answered, it is left alone for a while',
      () async {
    DateTime clock = DateTime(2026, 10, 2, 12);
    service = PortalConnectivityService(
      connect: () => DBusClient(address),
      callTimeout: const Duration(milliseconds: 200),
      now: () => clock,
    );
    portal.hold = Completer<void>();
    await startPortal();

    expect(await service.currentStatus(), NetworkStatus.unknown);
    expect(portal.calls, 1);
    // Playback asks again for the next track: answered at once, unasked.
    expect(await service.currentStatus(), NetworkStatus.unknown);
    expect(portal.calls, 1);

    portal.hold!.complete();
    portal.hold = null;
    clock = clock.add(const Duration(minutes: 2));
    expect(await service.currentStatus(), NetworkStatus.wifi);
  });

  test('callers asking at once share one question', () async {
    await startPortal();

    final List<NetworkStatus> answers = await Future.wait(
      <Future<NetworkStatus>>[
        service.currentStatus(),
        service.currentStatus(),
        service.currentStatus(),
      ],
    );

    expect(answers, everyElement(NetworkStatus.wifi));
    expect(portal.calls, 1);
  });

  test('no session bus reads as unknown', () async {
    portalSide = DBusClient(address);
    service = PortalConnectivityService(
      connect: () =>
          DBusClient(DBusAddress('unix:path=/nonexistent/linthra-test-bus')),
    );

    expect(await service.currentStatus(), NetworkStatus.unknown);
  });

  test('a session bus address it cannot use reads as unknown', () async {
    portalSide = DBusClient(address);
    for (final String unusable in <String>[
      'unixexec:path=/usr/bin/dbus-bridge',
      'not an address',
    ]) {
      final PortalConnectivityService odd = PortalConnectivityService(
        connect: () => DBusClient(DBusAddress(unusable)),
      );
      expect(await odd.currentStatus(), NetworkStatus.unknown,
          reason: unusable);
      await odd.dispose();
    }
  });

  test('a network change is reported to every listener', () async {
    await startPortal();
    final List<NetworkStatus> first = <NetworkStatus>[];
    final List<NetworkStatus> second = <NetworkStatus>[];
    final StreamSubscription<NetworkStatus> a =
        service.statusStream.listen(first.add);
    final StreamSubscription<NetworkStatus> b =
        service.statusStream.listen(second.add);
    // Let the signal subscription reach the bus before the portal emits.
    expect(await service.currentStatus(), NetworkStatus.wifi);

    await portal.change(metered: true);
    for (int i = 0; i < 100 && second.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(first, <NetworkStatus>[NetworkStatus.mobile]);
    expect(second, <NetworkStatus>[NetworkStatus.mobile]);
    await a.cancel();
    await b.cancel();
  });

  test('after dispose it asks nothing and reads as unknown', () async {
    await startPortal();
    await service.dispose();

    expect(await service.currentStatus(), NetworkStatus.unknown);
  });
}
