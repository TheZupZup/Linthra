import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The network security config carries two deliberate choices for a self-hosted
// app: cleartext http for LAN servers, and — issue #266 — HTTPS trust for
// user-installed CAs, so a private-CA / self-signed Jellyfin or Navidrome
// certificate works once its CA is installed on the device. Neither weakens
// TLS: chains and hostnames are still verified by the platform, and a
// certificate not anchored in the system or user store is still rejected.
// These checks keep both choices from silently regressing.
void main() {
  group('android network security config', () {
    late String config;

    setUpAll(() {
      config = File('android/app/src/main/res/xml/network_security_config.xml')
          .readAsStringSync();
    });

    test('the manifest binds the config', () {
      final String manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(
        manifest,
        contains(
            'android:networkSecurityConfig="@xml/network_security_config"'),
      );
    });

    test('cleartext stays permitted for LAN http servers', () {
      expect(config, contains('cleartextTrafficPermitted="true"'));
    });

    test('HTTPS trusts system CAs plus user-installed CAs (issue #266)', () {
      // Both anchors must be listed: declaring only "user" would drop system
      // trust; omitting "user" is Android's default and re-breaks private CAs.
      expect(config, contains('<certificates src="system" />'));
      expect(config, contains('<certificates src="user" />'));
    });
  });
}
