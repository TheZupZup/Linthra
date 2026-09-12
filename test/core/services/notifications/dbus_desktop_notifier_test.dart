import 'dart:async';
import 'dart:typed_data';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/notifications/dbus_desktop_notifier.dart';
import 'package:linthra/core/services/notifications/desktop_notifier.dart';

/// One call the notifier asked the bus to make.
class _Call {
  _Call(this.destination, this.interface, this.name, this.values);

  final String? destination;
  final String? interface;
  final String name;
  final List<DBusValue> values;
}

/// A [DBusClient] that answers like a bus without being one.
///
/// Subclassed rather than mocked because `DBusClient` is a concrete class and
/// its constructor is lazy: nothing connects until a method is called, and
/// the only method this notifier uses is overridden here. So these tests
/// exercise the real call-building code with no session bus, no portal and no
/// notification daemon anywhere in sight. Mirrors the MPRIS session's
/// `_FakeBus`.
class _FakeBus extends DBusClient {
  _FakeBus({this.portalVersion, this.daemon = true, this.hangs = false})
      : super(DBusAddress('unix:path=/nonexistent/linthra-test-bus'));

  /// The version the Notification portal reports, or null when there is no
  /// portal on this bus at all.
  final int? portalVersion;

  /// Whether `org.freedesktop.Notifications` answers.
  final bool daemon;

  /// A service that takes the call and never replies, the way a wedged daemon
  /// does.
  final bool hangs;

  final List<_Call> calls = <_Call>[];
  int closeCalls = 0;
  int nextNotificationId = 11;

  List<_Call> callsTo(String name) =>
      calls.where((_Call call) => call.name == name).toList();

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
  }) async {
    calls.add(
      _Call(destination, interface, name, values.toList()),
    );
    if (hangs) return Completer<DBusMethodSuccessResponse>().future;
    if (destination == 'org.freedesktop.portal.Desktop') {
      final int? version = portalVersion;
      if (version == null) {
        throw DBusServiceUnknownException(
          DBusMethodErrorResponse.unknownMethod(),
        );
      }
      if (name == 'Get') {
        return DBusMethodSuccessResponse(
          <DBusValue>[DBusVariant(DBusUint32(version))],
        );
      }
      return DBusMethodSuccessResponse();
    }
    if (!daemon) {
      throw DBusServiceUnknownException(
        DBusMethodErrorResponse.unknownMethod(),
      );
    }
    return DBusMethodSuccessResponse(
      <DBusValue>[DBusUint32(nextNotificationId++)],
    );
  }

  @override
  Future<void> close() async => closeCalls++;
}

/// The `a{sv}` body of an `AddNotification` call, as a plain map.
Map<String, DBusValue> _portalBody(_Call call) {
  final DBusDict dict = call.values[1] as DBusDict;
  return dict.children.map(
    (DBusValue key, DBusValue value) => MapEntry<String, DBusValue>(
      (key as DBusString).value,
      (value as DBusVariant).value,
    ),
  );
}

/// The `hints` argument of a `Notify` call, as a plain map.
Map<String, DBusValue> _hints(_Call call) {
  final DBusDict dict = call.values[6] as DBusDict;
  return dict.children.map(
    (DBusValue key, DBusValue value) => MapEntry<String, DBusValue>(
      (key as DBusString).value,
      (value as DBusVariant).value,
    ),
  );
}

void main() {
  const DesktopNotification plain = DesktopNotification(
    title: 'Trouble',
    body: 'Cat Power • Moon Pix',
  );
  final DesktopNotification withCover = DesktopNotification(
    title: 'Trouble',
    body: 'Cat Power • Moon Pix',
    image: Uri.file('/home/dana/.cache/linthra/media/9f.img'),
  );

  DBusDesktopNotifier notifierFor(
    _FakeBus bus, {
    Uint8List? cover,
  }) {
    return DBusDesktopNotifier(
      clientFactory: () => bus,
      readImage: (Uri _) async => cover,
    );
  }

  group('the portal route', () {
    test('is the one tried first, and carries title and body', () async {
      final _FakeBus bus = _FakeBus(portalVersion: 1);
      final DBusDesktopNotifier notifier = notifierFor(bus);
      addTearDown(notifier.dispose);

      await notifier.show(plain);

      expect(notifier.transport, NotificationTransport.portal);
      // Nothing was said to the spec interface at all.
      expect(bus.callsTo('Notify'), isEmpty);

      final _Call call = bus.callsTo('AddNotification').single;
      expect(call.destination, 'org.freedesktop.portal.Desktop');
      expect(call.interface, 'org.freedesktop.portal.Notification');
      expect(
        (call.values.first as DBusString).value,
        DBusDesktopNotifier.notificationId,
      );

      final Map<String, DBusValue> body = _portalBody(call);
      expect(body['title'], const DBusString('Trouble'));
      expect(body['body'], const DBusString('Cat Power • Moon Pix'));
      expect(body['priority'], const DBusString('low'));
    });

    test('reuses one id, so the shell keeps one entry', () async {
      final _FakeBus bus = _FakeBus(portalVersion: 1);
      final DBusDesktopNotifier notifier = notifierFor(bus);
      addTearDown(notifier.dispose);

      await notifier.show(plain);
      await notifier.show(withCover);

      final List<_Call> added = bus.callsTo('AddNotification');
      expect(added, hasLength(2));
      expect(
        added.map((_Call call) => (call.values.first as DBusString).value),
        everyElement(DBusDesktopNotifier.notificationId),
      );
    });

    test('reads the interface version once', () async {
      final _FakeBus bus = _FakeBus(portalVersion: 2);
      final DBusDesktopNotifier notifier = notifierFor(bus);
      addTearDown(notifier.dispose);

      await notifier.show(plain);
      await notifier.show(plain);

      expect(bus.callsTo('Get'), hasLength(1));
    });

    test('version 1 gets no cover: that icon form did not exist yet', () async {
      final _FakeBus bus = _FakeBus(portalVersion: 1);
      final DBusDesktopNotifier notifier = notifierFor(
        bus,
        cover: Uint8List.fromList(<int>[1, 2, 3]),
      );
      addTearDown(notifier.dispose);

      await notifier.show(withCover);

      expect(
          _portalBody(bus.callsTo('AddNotification').single)['icon'], isNull);
    });

    test('version 2 carries the cover as bytes', () async {
      final _FakeBus bus = _FakeBus(portalVersion: 2);
      final DBusDesktopNotifier notifier = notifierFor(
        bus,
        cover: Uint8List.fromList(<int>[1, 2, 3]),
      );
      addTearDown(notifier.dispose);

      await notifier.show(withCover);

      final DBusValue? icon =
          _portalBody(bus.callsTo('AddNotification').single)['icon'];
      expect(icon, isA<DBusStruct>());
      final DBusStruct serialized = icon! as DBusStruct;
      // g_icon_serialize's GBytesIcon form.
      expect(serialized.children.first, const DBusString('bytes'));
      expect(
        ((serialized.children.last as DBusVariant).value as DBusArray)
            .children
            .map((DBusValue byte) => (byte as DBusByte).value),
        <int>[1, 2, 3],
      );
    });

    test('a cover that cannot be read is simply no cover', () async {
      final _FakeBus bus = _FakeBus(portalVersion: 2);
      final DBusDesktopNotifier notifier = notifierFor(bus);
      addTearDown(notifier.dispose);

      await notifier.show(withCover);

      expect(notifier.transport, NotificationTransport.portal);
      expect(
          _portalBody(bus.callsTo('AddNotification').single)['icon'], isNull);
    });
  });

  group('the freedesktop route', () {
    test('takes over on a host with no portal', () async {
      final _FakeBus bus = _FakeBus();
      final DBusDesktopNotifier notifier = notifierFor(bus);
      addTearDown(notifier.dispose);

      await notifier.show(withCover);

      expect(notifier.transport, NotificationTransport.freedesktop);
      final _Call call = bus.callsTo('Notify').single;
      expect(call.destination, 'org.freedesktop.Notifications');
      expect((call.values[3] as DBusString).value, 'Trouble');
      expect((call.values[4] as DBusString).value, 'Cat Power • Moon Pix');
      // No actions: the shell's transport controls are MPRIS's job.
      expect((call.values[5] as DBusArray).children, isEmpty);

      final Map<String, DBusValue> hints = _hints(call);
      expect(hints['urgency'], const DBusByte(0));
      expect(hints['transient'], const DBusBoolean(true));
      expect(
        hints['desktop-entry'],
        const DBusString(DBusDesktopNotifier.desktopEntry),
      );
      expect(
        hints['image-path'],
        DBusString(
            Uri.file('/home/dana/.cache/linthra/media/9f.img').toString()),
      );
    });

    test('a notification with no cover sends no image hint', () async {
      final _FakeBus bus = _FakeBus();
      final DBusDesktopNotifier notifier = notifierFor(bus);
      addTearDown(notifier.dispose);

      await notifier.show(plain);

      expect(_hints(bus.callsTo('Notify').single)['image-path'], isNull);
    });

    test('replaces the previous notification instead of stacking', () async {
      final _FakeBus bus = _FakeBus();
      final DBusDesktopNotifier notifier = notifierFor(bus);
      addTearDown(notifier.dispose);

      await notifier.show(plain);
      await notifier.show(plain);
      await notifier.show(plain);

      expect(
        bus
            .callsTo('Notify')
            .map((_Call call) => (call.values[1] as DBusUint32).value),
        // The first has nothing to replace; each one after replaces the id the
        // daemon just handed back.
        <int>[0, 11, 12],
      );
    });

    test('the route it found is remembered, so the portal is not re-probed',
        () async {
      final _FakeBus bus = _FakeBus();
      final DBusDesktopNotifier notifier = notifierFor(bus);
      addTearDown(notifier.dispose);

      await notifier.show(plain);
      await notifier.show(plain);

      expect(bus.callsTo('AddNotification'), isEmpty);
      // One failed probe in total, on the first notification only.
      expect(bus.callsTo('Get'), hasLength(1));
      expect(bus.callsTo('Notify'), hasLength(2));
    });
  });

  group('when nothing answers', () {
    test('show completes quietly and keeps no route', () async {
      final _FakeBus bus = _FakeBus(daemon: false);
      final DBusDesktopNotifier notifier = notifierFor(bus);
      addTearDown(notifier.dispose);

      await expectLater(notifier.show(plain), completes);

      expect(notifier.transport, isNull);
      // Both routes were tried, and both failures were swallowed.
      expect(bus.callsTo('Get'), hasLength(1));
      expect(bus.callsTo('Notify'), hasLength(1));
    });

    test('a daemon that shows up later is found on the next notification',
        () async {
      final _FakeBus bus = _FakeBus(daemon: false);
      final DBusDesktopNotifier notifier = notifierFor(bus);
      addTearDown(notifier.dispose);

      await notifier.show(plain);
      // Nothing is pinned, so the next attempt probes again rather than
      // assuming the desktop is still empty.
      expect(notifier.transport, isNull);
      expect(bus.callsTo('Notify'), hasLength(1));
    });

    test('a service that never replies is given up on', () async {
      final _FakeBus bus = _FakeBus(hangs: true);
      final DBusDesktopNotifier notifier = DBusDesktopNotifier(
        clientFactory: () => bus,
        readImage: (Uri _) async => null,
        callDeadline: const Duration(milliseconds: 20),
      );
      addTearDown(notifier.dispose);

      // Nothing awaits a notification, so a wedged daemon must not leave one
      // outstanding per track change for the rest of the session.
      await expectLater(notifier.show(plain), completes);
      expect(notifier.transport, isNull);
    });

    test('a bus that cannot even be opened is not an error', () async {
      final DBusDesktopNotifier notifier = DBusDesktopNotifier(
        clientFactory: () => throw StateError('no session bus'),
      );
      addTearDown(notifier.dispose);

      await expectLater(notifier.show(plain), completes);
      expect(notifier.transport, isNull);
    });
  });

  group('dispose', () {
    test('closes the connection it opened', () async {
      final _FakeBus bus = _FakeBus(portalVersion: 1);
      final DBusDesktopNotifier notifier = notifierFor(bus);

      await notifier.show(plain);
      await notifier.dispose();

      expect(bus.closeCalls, 1);
    });

    test('is idempotent, and shows nothing afterwards', () async {
      final _FakeBus bus = _FakeBus(portalVersion: 1);
      final DBusDesktopNotifier notifier = notifierFor(bus);

      await notifier.show(plain);
      await notifier.dispose();
      await notifier.dispose();
      await notifier.show(plain);

      expect(bus.closeCalls, 1);
      expect(bus.callsTo('AddNotification'), hasLength(1));
    });

    test('opens nothing when there was nothing to close', () async {
      final _FakeBus bus = _FakeBus(portalVersion: 1);
      final DBusDesktopNotifier notifier = notifierFor(bus);

      await notifier.dispose();

      expect(bus.closeCalls, 0);
      expect(bus.calls, isEmpty);
    });
  });
}
