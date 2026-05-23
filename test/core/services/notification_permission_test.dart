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
  });

  group('NoopNotificationPermission', () {
    test('does nothing and completes', () async {
      const permission = NoopNotificationPermission();
      await expectLater(permission.ensureGranted(), completes);
    });
  });
}
