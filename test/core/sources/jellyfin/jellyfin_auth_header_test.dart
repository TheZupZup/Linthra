import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/app_info.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_auth_header.dart';

void main() {
  group('JellyfinAuthHeader', () {
    test('forClient identifies the app and device but carries no token', () {
      final String header = JellyfinAuthHeader.forClient('device-123');

      expect(header, startsWith('MediaBrowser '));
      expect(header, contains('Client="${AppInfo.name}"'));
      expect(header, contains('Device="${AppInfo.name}"'));
      expect(header, contains('DeviceId="device-123"'));
      expect(header, contains('Version="${AppInfo.version}"'));
      expect(header, isNot(contains('Token=')));
    });

    test('forToken adds the token to the client header', () {
      final String header =
          JellyfinAuthHeader.forToken('device-123', 'secret-token');

      expect(header, contains('DeviceId="device-123"'));
      expect(header, contains('Token="secret-token"'));
    });
  });
}
