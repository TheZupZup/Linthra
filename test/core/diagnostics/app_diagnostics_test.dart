import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/diagnostics/app_diagnostics.dart';
import 'package:linthra/core/models/cache_size.dart';

void main() {
  group('AppDiagnostics.hostOnly', () {
    test('reduces a full base URL to its host', () {
      expect(
        AppDiagnostics.hostOnly('https://music.example.com/jellyfin'),
        'music.example.com',
      );
    });

    test('keeps a port when present', () {
      expect(
        AppDiagnostics.hostOnly('http://192.168.1.10:8096'),
        '192.168.1.10:8096',
      );
    });

    test('reduces a bare host (no scheme), keeping its port', () {
      expect(AppDiagnostics.hostOnly('music.example.com'), 'music.example.com');
      expect(
        AppDiagnostics.hostOnly('music.example.com:8096'),
        'music.example.com:8096',
      );
    });

    test('drops scheme, path, query, and userinfo so no secret rides along',
        () {
      final String? host = AppDiagnostics.hostOnly(
        'https://user:pass@music.example.com/Audio/t1/stream?api_key=secret',
      );
      expect(host, 'music.example.com');
      expect(host, isNot(contains('secret')));
      expect(host, isNot(contains('api_key')));
      expect(host, isNot(contains('pass')));
      expect(host, isNot(contains('https')));
    });

    test('returns null for null or empty input', () {
      expect(AppDiagnostics.hostOnly(null), isNull);
      expect(AppDiagnostics.hostOnly(''), isNull);
      expect(AppDiagnostics.hostOnly('   '), isNull);
    });
  });

  group('AppDiagnostics.redactPath', () {
    test('reduces a private path to its basename behind a marker', () {
      expect(
        AppDiagnostics.redactPath('/data/user/0/com.linthra/files/diag.txt'),
        '…/diag.txt',
      );
    });

    test('redacts so the private directory tree never appears', () {
      final String? redacted =
          AppDiagnostics.redactPath('/home/alice/secret-folder/diag.txt');
      expect(redacted, '…/diag.txt');
      expect(redacted, isNot(contains('alice')));
      expect(redacted, isNot(contains('secret-folder')));
    });

    test('returns null for null/empty', () {
      expect(AppDiagnostics.redactPath(null), isNull);
      expect(AppDiagnostics.redactPath(''), isNull);
    });
  });

  group('AppDiagnostics.report', () {
    test('includes the requested diagnostic fields', () {
      final String report = AppDiagnostics.report(
        const AppDiagnosticsData(
          appVersion: '0.1.0-alpha.15',
          androidVersion: 'Android 14 (API 34)',
          deviceModel: 'Pixel 7',
          jellyfinState: 'connected',
          jellyfinHost: 'music.example.com',
          subsonicState: 'disconnected',
          subsonicHost: 'navi.example.com',
          libraryTrackCount: 1234,
          cacheUsedBytes: 2 * CacheSize.bytesPerGb,
          cacheLimitBytes: 4 * CacheSize.bytesPerGb,
          playbackOutput: 'cast',
          lastErrorKind: 'unauthorized',
          castAvailable: true,
          castConnected: true,
          androidAutoSupported: true,
          offlineCacheEnabled: true,
          smartPrecacheEnabled: false,
        ),
      );

      expect(report, contains('Linthra diagnostics'));
      expect(report, contains('App version: 0.1.0-alpha.15'));
      expect(report, contains('Android: Android 14 (API 34)'));
      expect(report, contains('Device: Pixel 7'));
      expect(report, contains('Jellyfin: connected'));
      expect(report, contains('Jellyfin host: music.example.com'));
      expect(report, contains('Subsonic: disconnected'));
      expect(report, contains('Subsonic host: navi.example.com'));
      expect(report, contains('Library tracks: 1234'));
      expect(report, contains('Cache: 2 GB of 4 GB'));
      expect(report, contains('Playback output: cast'));
      expect(report, contains('Last error: unauthorized'));
      expect(report, contains('Cast available: yes'));
      expect(report, contains('Cast connected: yes'));
      expect(report, contains('Android Auto supported: yes'));
      expect(report, contains('Offline cache: enabled'));
      expect(report, contains('Smart pre-cache: disabled'));
    });

    test('includes the playback state and a hashed current-track id', () {
      final String report = AppDiagnostics.report(
        const AppDiagnosticsData(
          appVersion: '0.1.0',
          playbackOutput: 'local',
          playbackStatus: 'playing',
          currentTrackIdHash: 'id#1a2b3c',
        ),
      );

      expect(report, contains('Playback output: local'));
      expect(report, contains('Playback state: playing'));
      // A hash tag — never a raw id, title, or URI.
      expect(report, contains('Current track: id#1a2b3c'));
    });

    test('omits the playback state / current track lines when absent', () {
      final String report =
          AppDiagnostics.report(const AppDiagnosticsData(appVersion: '0.1.0'));

      expect(report, isNot(contains('Playback state:')));
      expect(report, isNot(contains('Current track:')));
    });

    test('omits absent optional fields but always reports app version', () {
      final String report =
          AppDiagnostics.report(const AppDiagnosticsData(appVersion: '0.1.0'));

      expect(report, contains('App version: 0.1.0'));
      expect(report, isNot(contains('Android:')));
      expect(report, isNot(contains('Device:')));
      expect(report, isNot(contains('Jellyfin:')));
      expect(report, isNot(contains('Jellyfin host:')));
      expect(report, isNot(contains('Subsonic:')));
      expect(report, isNot(contains('Library tracks:')));
      expect(report, isNot(contains('Cache:')));
      expect(report, isNot(contains('Playback output:')));
      expect(report, isNot(contains('Smart pre-cache:')));
      // No error → reported explicitly as none.
      expect(report, contains('Last error: none'));
      // Booleans default to the safe/off side.
      expect(report, contains('Cast available: no'));
      expect(report, contains('Offline cache: disabled'));
    });

    test(
        'never emits a token, password, or full authenticated URL even when a '
        'caller mistakenly passes one as a host', () {
      // The two host fields are forced through hostOnly by report(), so even a
      // full authenticated URL handed in cannot leak its token/credentials.
      final String report = AppDiagnostics.report(
        const AppDiagnosticsData(
          appVersion: '0.1.0',
          jellyfinState: 'connected',
          jellyfinHost: 'https://user:hunter2@music.example.com/Audio/t1/stream'
              '?api_key=tok-secret',
          subsonicState: 'connected',
          subsonicHost:
              'https://navi.example.com/rest/stream.view?u=bob&p=enc:abcdef'
              '&t=md5tok&s=salt123',
          lastErrorKind: 'unauthorized',
        ),
      );

      expect(report, contains('Jellyfin host: music.example.com'));
      expect(report, contains('Subsonic host: navi.example.com'));
      // None of the secret material survives.
      expect(report, isNot(contains('tok-secret')));
      expect(report, isNot(contains('api_key')));
      expect(report, isNot(contains('hunter2')));
      expect(report, isNot(contains('md5tok')));
      expect(report, isNot(contains('salt123')));
      expect(report, isNot(contains('enc:')));
      expect(report, isNot(contains('/Audio/')));
      expect(report, isNot(contains('/rest/')));
      expect(report.toLowerCase(), isNot(contains('password')));
      expect(report.toLowerCase(), isNot(contains('authorization')));
      expect(report.toLowerCase(), isNot(contains('bearer')));
    });
  });
}
