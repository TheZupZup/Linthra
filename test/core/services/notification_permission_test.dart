import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/notification_permission.dart';

void main() {
  group('PermissionHandlerNotificationPermission', () {
    test('is a no-op (never throws) off Android', () async {
      // The test host is not Android, so the request short-circuits before ever
      // touching the plugin channel. This guards the early-return so startup is
      // never blocked or crashed by the permission request on other platforms.
      const permission = PermissionHandlerNotificationPermission();
      await expectLater(permission.ensureGranted(), completes);
    });

    test('status reads as unknown off Android (no runtime gate)', () async {
      // Off Android there is no POST_NOTIFICATIONS gate, so the status read
      // short-circuits to `unknown` without touching the plugin channel.
      const permission = PermissionHandlerNotificationPermission();
      await expectLater(
        permission.status(),
        completion(NotificationPermissionStatus.unknown),
      );
    });
  });

  group('NoopNotificationPermission', () {
    test('does nothing and completes', () async {
      const permission = NoopNotificationPermission();
      await expectLater(permission.ensureGranted(), completes);
    });

    test('reports an unknown status', () async {
      const permission = NoopNotificationPermission();
      await expectLater(
        permission.status(),
        completion(NotificationPermissionStatus.unknown),
      );
    });
  });

  group('NotificationPermissionStatus.label', () {
    test('maps each state to a stable, secret-free label', () {
      expect(NotificationPermissionStatus.granted.label, 'granted');
      expect(NotificationPermissionStatus.denied.label, 'denied');
      expect(NotificationPermissionStatus.unknown.label, 'unknown');
    });
  });
}
