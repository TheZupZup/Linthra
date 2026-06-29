import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_server_capabilities.dart';

void main() {
  group('JellyfinServerInfo.fromJson', () {
    test('parses the public info fields', () {
      final JellyfinServerInfo? info =
          JellyfinServerInfo.fromJson(<String, dynamic>{
        'ServerName': 'Home',
        'Version': '10.9.11',
        'Id': 'abc123',
        'ProductName': 'Jellyfin Server',
        'OperatingSystem': 'Linux',
      });

      expect(info, isNotNull);
      expect(info!.serverName, 'Home');
      expect(info.version, '10.9.11');
      expect(info.id, 'abc123');
      expect(info.productName, 'Jellyfin Server');
      expect(info.operatingSystem, 'Linux');
    });

    test('tolerates the optional product/OS fields being absent', () {
      final JellyfinServerInfo? info =
          JellyfinServerInfo.fromJson(<String, dynamic>{
        'ServerName': 'Home',
        'Version': '10.9.0',
      });

      expect(info, isNotNull);
      expect(info!.productName, isNull);
      expect(info.operatingSystem, isNull);
    });

    test('returns null when a required field is missing', () {
      expect(
        JellyfinServerInfo.fromJson(<String, dynamic>{'ServerName': 'Home'}),
        isNull,
      );
      expect(
        JellyfinServerInfo.fromJson(<String, dynamic>{'Version': '10.9.0'}),
        isNull,
      );
    });

    test('returns null (clean fail) when a required field is the wrong type',
        () {
      // A server that sends Version or ServerName as a number reads as "not a
      // Jellyfin server" rather than throwing a TypeError on an `as String`.
      expect(
        JellyfinServerInfo.fromJson(<String, dynamic>{
          'ServerName': 'Home',
          'Version': 12,
        }),
        isNull,
      );
      expect(
        JellyfinServerInfo.fromJson(<String, dynamic>{
          'ServerName': 99,
          'Version': '12.0.0',
        }),
        isNull,
      );
    });

    test('degrades retyped optional fields to null, still parsing', () {
      final JellyfinServerInfo? info =
          JellyfinServerInfo.fromJson(<String, dynamic>{
        'ServerName': 'Home',
        'Version': '12.0.0',
        'Id': 123,
        'ProductName': <String, dynamic>{'weird': true},
        'OperatingSystem': <dynamic>[],
      });
      expect(info, isNotNull);
      expect(info!.serverName, 'Home');
      expect(info.version, '12.0.0');
      expect(info.id, isNull);
      expect(info.productName, isNull);
      expect(info.operatingSystem, isNull);
    });

    test('exposes parsed version and support classification', () {
      const JellyfinServerInfo current =
          JellyfinServerInfo(serverName: 'Home', version: '10.9.11');
      expect(current.parsedVersion, const JellyfinServerVersion(10, 9, 11));
      expect(current.support, JellyfinServerSupport.supported);

      const JellyfinServerInfo old =
          JellyfinServerInfo(serverName: 'Old', version: '10.6.0');
      expect(old.support, JellyfinServerSupport.untested);

      const JellyfinServerInfo weird =
          JellyfinServerInfo(serverName: 'Weird', version: 'custom-build');
      expect(weird.parsedVersion, isNull);
      expect(weird.support, JellyfinServerSupport.unknown);

      // A Jellyfin 12 release candidate parses and is flagged forward-tolerant.
      const JellyfinServerInfo newer =
          JellyfinServerInfo(serverName: 'Next', version: '12.0.0-rc1');
      expect(newer.parsedVersion, const JellyfinServerVersion(12, 0, 0));
      expect(newer.support, JellyfinServerSupport.newerUntested);
    });
  });
}
