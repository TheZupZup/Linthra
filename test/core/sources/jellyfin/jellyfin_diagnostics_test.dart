import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_diagnostics.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_server_capabilities.dart';

void main() {
  group('JellyfinDiagnostics.hostOnly', () {
    test('reduces a full base URL to its host', () {
      expect(
        JellyfinDiagnostics.hostOnly('https://music.example.com/jellyfin'),
        'music.example.com',
      );
    });

    test('keeps a port when present', () {
      expect(
        JellyfinDiagnostics.hostOnly('http://192.168.1.10:8096'),
        '192.168.1.10:8096',
      );
    });

    test('drops scheme, path, and query (so no token can ride along)', () {
      final String? host = JellyfinDiagnostics.hostOnly(
        'https://music.example.com/Audio/t1/stream?api_key=secret',
      );
      expect(host, 'music.example.com');
      expect(host, isNot(contains('secret')));
      expect(host, isNot(contains('api_key')));
      expect(host, isNot(contains('https')));
    });

    test('returns null for empty or hostless input', () {
      expect(JellyfinDiagnostics.hostOnly(null), isNull);
      expect(JellyfinDiagnostics.hostOnly(''), isNull);
    });
  });

  group('JellyfinDiagnostics.describe', () {
    test('includes the app version, connection, server version, and host', () {
      final String report = JellyfinDiagnostics.describe(
        appVersion: '0.1.0-alpha.9',
        connectionState: 'connected',
        serverHost: 'music.example.com',
        serverName: 'Home',
        serverVersion: '10.9.11',
        productName: 'Jellyfin Server',
        versionSupport: JellyfinServerSupport.supported,
        lastErrorKind: null,
      );

      expect(report, contains('App version: 0.1.0-alpha.9'));
      expect(report, contains('Connection: connected'));
      expect(report, contains('Server version: 10.9.11'));
      expect(report, contains('Server host: music.example.com'));
      expect(report, contains('Version support: supported'));
      // No error → reported explicitly as none.
      expect(report, contains('Last error: none'));
    });

    test('reports the last error kind when present', () {
      final String report = JellyfinDiagnostics.describe(
        appVersion: '0.1.0',
        connectionState: 'connected',
        lastErrorKind: 'unauthorized',
      );
      expect(report, contains('Last error: unauthorized'));
    });

    test('never contains a token, password, or full authenticated URL', () {
      // Even if a caller mistakenly passed secrets, there is no field for them;
      // and the host field is host-only. This asserts the shape stays safe.
      final String report = JellyfinDiagnostics.describe(
        appVersion: '0.1.0',
        connectionState: 'connected',
        serverHost: JellyfinDiagnostics.hostOnly(
          'https://music.example.com/Audio/t1/stream?api_key=tok-secret',
        ),
        serverName: 'Home',
        serverVersion: '10.9.11',
      );

      expect(report, isNot(contains('tok-secret')));
      expect(report, isNot(contains('api_key')));
      expect(report, isNot(contains('Token')));
      expect(report, isNot(contains('password')));
      expect(report, isNot(contains('/Audio/')));
    });

    test('omits absent optional fields', () {
      final String report = JellyfinDiagnostics.describe(
        appVersion: '0.1.0',
        connectionState: 'disconnected',
      );
      expect(report, isNot(contains('Server name:')));
      expect(report, isNot(contains('Server version:')));
      expect(report, isNot(contains('Server host:')));
      expect(report, contains('Connection: disconnected'));
    });
  });
}
