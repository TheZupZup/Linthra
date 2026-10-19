import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/diagnostics/app_diagnostics.dart';
import 'package:linthra/core/models/cache_size.dart';

void main() {
  group('AppDiagnostics.describeServer', () {
    test('names the scheme, the network and the kind of port', () {
      expect(
        AppDiagnostics.describeServer('https://music.example.com/jellyfin'),
        'https, unknown network (hostname), default port',
      );
      expect(
        AppDiagnostics.describeServer('http://192.168.1.10:8096'),
        'http, local network, custom port',
      );
    });

    test("an explicit default port reads as the scheme's default", () {
      expect(
        AppDiagnostics.describeServer('https://203.0.113.7:443'),
        'https, public network, default port',
      );
      expect(
        AppDiagnostics.describeServer('http://203.0.113.7:80'),
        'http, public network, default port',
      );
      expect(
        AppDiagnostics.describeServer('https://203.0.113.7:80'),
        'https, public network, custom port',
      );
    });

    test('names the network of an IP literal by its range', () {
      const Map<String, String> networks = <String, String>{
        'http://127.0.0.1': 'loopback',
        'http://127.4.5.6': 'loopback',
        'http://[::1]': 'loopback',
        'http://10.0.0.5': 'local network',
        'http://172.16.0.5': 'local network',
        'http://172.31.255.5': 'local network',
        'http://192.168.1.10': 'local network',
        'http://169.254.10.20': 'local network',
        'http://[fd12:3456::1]': 'local network',
        'http://[fe80::1]': 'local network',
        'http://[fe80::1%25eth0]': 'local network',
        'http://100.64.0.1': 'VPN/CGNAT range',
        'http://100.101.102.103': 'VPN/CGNAT range',
        'http://100.127.255.254': 'VPN/CGNAT range',
        'http://100.63.255.255': 'public network',
        'http://100.128.0.1': 'public network',
        'http://172.15.0.5': 'public network',
        'http://172.32.0.5': 'public network',
        'http://198.51.100.7': 'public network',
        'http://[2001:db8::1]': 'public network',
        'http://0.0.0.0': 'unknown network',
        'http://224.0.0.1': 'unknown network',
        'http://255.255.255.255': 'unknown network',
        'http://[ff02::1]': 'unknown network',
        'http://[::ffff:192.168.1.10]': 'unknown network',
      };
      networks.forEach((String address, String network) {
        expect(
          AppDiagnostics.describeServer(address),
          'http, $network, default port',
          reason: address,
        );
      });
    });

    test('only names the network of a hostname when the name proves it', () {
      expect(
        AppDiagnostics.describeServer('http://localhost:8096'),
        'http, loopback, custom port',
      );
      expect(
        AppDiagnostics.describeServer('https://MyNAS.Local:8920'),
        'https, local network (.local name), custom port',
      );
      // Anything else could resolve to a LAN or a public address.
      for (final String address in <String>[
        'https://jellyfin.example.com',
        'http://nas:4533',
        'https://nas.tail1234.ts.net',
        'http://music.lan',
        'http://2130706433',
      ]) {
        expect(
          AppDiagnostics.describeServer(address),
          contains('unknown network (hostname)'),
          reason: address,
        );
      }
    });

    test('a scheme-less address still gets a description', () {
      expect(
        AppDiagnostics.describeServer('music.example.com'),
        'unknown scheme, unknown network (hostname), default port',
      );
      expect(
        AppDiagnostics.describeServer('192.168.1.10:8096'),
        'unknown scheme, local network, custom port',
      );
    });

    test('returns null for null or empty input', () {
      expect(AppDiagnostics.describeServer(null), isNull);
      expect(AppDiagnostics.describeServer(''), isNull);
      expect(AppDiagnostics.describeServer('   '), isNull);
    });

    test('never copies any part of a personal address', () {
      // The description is built from fixed words only, so nothing of the
      // address can appear in it: no host, IP, port number, user, password,
      // path or query.
      final RegExp fixedWords = RegExp(
        r'^(https?|unknown scheme), '
        r'(loopback|local network|local network \(\.local name\)|'
        r'VPN/CGNAT range|public network|unknown network|'
        r'unknown network \(hostname\)), '
        r'(default|custom) port$',
      );
      const Map<String, List<String>> addresses = <String, List<String>>{
        'https://alice:hunter2@jellyfin.smith-family.net:8920/jf'
            '?api_key=tok-secret': <String>[
          'alice',
          'hunter2',
          'smith-family',
          'jellyfin.',
          '8920',
          'api_key',
          'tok-secret',
        ],
        'http://203.0.113.42:4533/rest/ping.view?u=bob&t=md5tok&s=salt123':
            <String>['203.0.113.42', '4533', 'bob', 'md5tok', 'salt123'],
        'http://192.168.1.10:8096': <String>['192.168', '8096'],
        'http://100.101.102.103:4533': <String>['100.101', '4533'],
        'https://alices-macbook.local:8920': <String>['alices-macbook'],
        'https://nas.tail1234.ts.net': <String>['tail1234', 'ts.net'],
        'http://[2001:db8:85a3::8a2e:370:7334]:8096': <String>['2001', '7334'],
        'bob:pw-secret@navi.example.org:4533/rest?t=tok': <String>[
          'bob',
          'pw-secret',
          'navi',
          'example.org',
          'tok'
        ],
      };
      addresses.forEach((String address, List<String> personal) {
        final String? description = AppDiagnostics.describeServer(address);
        expect(description, matches(fixedWords), reason: address);
        expect(description, isNot(matches(RegExp(r'[0-9@?=]'))),
            reason: address);
        for (final String fragment in personal) {
          expect(description, isNot(contains(fragment)), reason: address);
        }
      });
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
          jellyfinHost: 'https://music.example.com',
          subsonicState: 'disconnected',
          subsonicHost: 'http://192.168.1.20:4533',
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
      expect(
        report,
        contains('Jellyfin server: https, unknown network (hostname), '
            'default port'),
      );
      expect(report, contains('Subsonic: disconnected'));
      expect(
        report,
        contains('Subsonic server: http, local network, custom port'),
      );
      expect(report, isNot(contains('music.example.com')));
      expect(report, isNot(contains('192.168.1.20')));
      expect(report, isNot(contains('4533')));
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

    test('includePlayback: false drops every playback line', () {
      final String report = AppDiagnostics.report(
        const AppDiagnosticsData(
          appVersion: '0.1.0',
          playbackOutput: 'local',
          playbackStatus: 'playing',
          currentTrackIdHash: 'id#1a2b3c',
        ),
        includePlayback: false,
      );

      expect(report, isNot(contains('Playback output:')));
      expect(report, isNot(contains('Playback state:')));
      expect(report, isNot(contains('Current track:')));
    });

    test('includes the background-playback diagnostic fields', () {
      final String report = AppDiagnostics.report(
        const AppDiagnosticsData(
          appVersion: '0.1.0',
          notificationPermission: 'denied',
          lastLifecycleState: 'paused',
          playbackStateAtBackground: 'playing',
          lastInterruptionKind: 'connectionLost',
        ),
      );

      expect(report, contains('Notification permission: denied'));
      expect(report, contains('Last lifecycle: paused'));
      expect(report, contains('Playback at last background: playing'));
      expect(report, contains('Last interruption: connectionLost'));
    });

    test('includePlayback: false drops the background-playback playback lines',
        () {
      final String report = AppDiagnostics.report(
        const AppDiagnosticsData(
          appVersion: '0.1.0',
          notificationPermission: 'granted',
          lastLifecycleState: 'resumed',
          playbackStateAtBackground: 'buffering',
          lastInterruptionKind: 'connectionLost',
        ),
        includePlayback: false,
      );

      // Notification permission and lifecycle carry no track info, so they stay.
      expect(report, contains('Notification permission: granted'));
      expect(report, contains('Last lifecycle: resumed'));
      // The playback-describing lines are dropped with the rest of playback.
      expect(report, isNot(contains('Playback at last background:')));
      expect(report, isNot(contains('Last interruption:')));
    });

    test('the background-playback diagnostics never carry a secret', () {
      // Every field here is a fixed enum-name/label, so a report built from a
      // backgrounded streaming session leaks no token, URL, or track identity.
      final String report = AppDiagnostics.report(
        const AppDiagnosticsData(
          appVersion: '0.1.0',
          playbackOutput: 'local',
          playbackStatus: 'buffering',
          notificationPermission: 'granted',
          lastLifecycleState: 'paused',
          playbackStateAtBackground: 'buffering',
          lastInterruptionKind: 'connectionLost',
        ),
      );

      expect(report.toLowerCase(), isNot(contains('http')));
      expect(report.toLowerCase(), isNot(contains('token')));
      expect(report, isNot(contains('api_key')));
      expect(report.toLowerCase(), isNot(contains('authorization')));
      expect(report.toLowerCase(), isNot(contains('bearer')));
    });

    test('omits the background-playback fields when absent', () {
      final String report =
          AppDiagnostics.report(const AppDiagnosticsData(appVersion: '0.1.0'));

      expect(report, isNot(contains('Notification permission:')));
      expect(report, isNot(contains('Last lifecycle:')));
      expect(report, isNot(contains('Playback at last background:')));
      expect(report, isNot(contains('Last interruption:')));
    });

    test('includeCache: false drops the cache line', () {
      final String report = AppDiagnostics.report(
        const AppDiagnosticsData(
          appVersion: '0.1.0',
          cacheUsedBytes: 2 * CacheSize.bytesPerGb,
          cacheLimitBytes: 4 * CacheSize.bytesPerGb,
        ),
        includeCache: false,
      );

      expect(report, isNot(contains('Cache:')));
    });

    test('omits absent optional fields but always reports app version', () {
      final String report =
          AppDiagnostics.report(const AppDiagnosticsData(appVersion: '0.1.0'));

      expect(report, contains('App version: 0.1.0'));
      expect(report, isNot(contains('Android:')));
      expect(report, isNot(contains('Device:')));
      expect(report, isNot(contains('Jellyfin:')));
      expect(report, isNot(contains('Jellyfin server:')));
      expect(report, isNot(contains('Subsonic:')));
      expect(report, isNot(contains('Subsonic server:')));
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
      // The two host fields are forced through describeServer by report(), so
      // even a full authenticated URL handed in cannot leak its host, token or
      // credentials.
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

      expect(
        report,
        contains('Jellyfin server: https, unknown network (hostname), '
            'default port'),
      );
      expect(
        report,
        contains('Subsonic server: https, unknown network (hostname), '
            'default port'),
      );
      // None of the secret material survives, and neither does the host.
      expect(report, isNot(contains('music.example.com')));
      expect(report, isNot(contains('navi.example.com')));
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

    test('a personal server address never reaches the report', () {
      // The report goes into public issues, so a self-hosted server's name,
      // IP or port must not be in it. What is left still tells a LAN-only
      // server from a public one.
      final String report = AppDiagnostics.report(
        const AppDiagnosticsData(
          appVersion: '0.1.0',
          jellyfinState: 'configured (unreachable)',
          jellyfinHost: 'https://jellyfin.alice-smith.net:8920',
          subsonicState: 'connected',
          subsonicHost: 'http://100.101.102.103:4533',
        ),
      );

      expect(
        report,
        contains('Jellyfin server: https, unknown network (hostname), '
            'custom port'),
      );
      expect(
        report,
        contains('Subsonic server: http, VPN/CGNAT range, custom port'),
      );
      expect(report, isNot(contains('alice-smith')));
      expect(report, isNot(contains('jellyfin.')));
      expect(report, isNot(contains('8920')));
      expect(report, isNot(contains('100.101')));
      expect(report, isNot(contains('4533')));
      expect(report, isNot(contains(' host:')));
    });
  });

  group('AppDiagnostics.report local scan diagnostics', () {
    test('reports the selected folder, access, scan counts, and error', () {
      final String report = AppDiagnostics.report(
        const AppDiagnosticsData(
          appVersion: '0.1.0',
          localFolderSelected: true,
          localPersistedPermission: true,
          localScanFilesVisited: 120,
          localScanFoldersVisited: 7,
          localScanAudioCandidates: 98,
          localScanImportedTracks: 97,
          localScanSkippedUnsupported: 22,
          localScanReadFailures: 0,
          localScanRecursive: true,
          localSupportedExtensions: <String>['flac', 'm4a', 'mp3'],
        ),
      );

      expect(report, contains('Local folder: selected'));
      expect(report, contains('Local folder access: persisted'));
      expect(
        report,
        contains('Local scan: visited 120 files, 7 folders, audio 98, '
            'imported 97, skipped 22, read failures 0'),
      );
      expect(report, contains('Local scan recursive: yes'));
      expect(report, contains('Local supported types: flac, m4a, mp3'));
      // A completed scan reports a positive status, not just the absence of an
      // error line.
      expect(report, contains('Local scan status: ok'));
      expect(report, isNot(contains('Local scan error:')));
    });

    test('reports a missing folder and a lost grant plainly', () {
      final String report = AppDiagnostics.report(
        const AppDiagnosticsData(
          appVersion: '0.1.0',
          localFolderSelected: false,
        ),
      );

      expect(report, contains('Local folder: not selected'));
      // No persisted-permission line when the flag is unknown/not applicable.
      expect(report, isNot(contains('Local folder access:')));
    });

    test('reports a not-persisted SAF grant — the removable-SD signal', () {
      final String report = AppDiagnostics.report(
        const AppDiagnosticsData(
          appVersion: '0.1.0',
          localFolderSelected: true,
          localPersistedPermission: false,
          localScanFilesVisited: 0,
          localScanAudioCandidates: 0,
          localScanSkippedUnsupported: 0,
          localScanReadFailures: 4,
        ),
      );

      expect(report, contains('Local folder access: not persisted'));
      expect(report, contains('read failures 4'));
    });

    test('names a scan could not open are counted, not named (#817)', () {
      final String report = AppDiagnostics.report(
        const AppDiagnosticsData(
          appVersion: '0.1.0',
          localFolderSelected: true,
          localScanFilesVisited: 3,
          localScanAudioCandidates: 3,
          localScanSkippedUnsupported: 0,
          localScanReadFailures: 0,
          localScanUnopenableNames: 2,
        ),
      );

      expect(report, contains('read failures 0, unopenable names 2'));
    });

    test('a completed scan with no error still reports a positive status', () {
      final String report = AppDiagnostics.report(
        const AppDiagnosticsData(
          appVersion: '0.1.0',
          localFolderSelected: true,
          localScanFilesVisited: 0,
          localScanFoldersVisited: 1,
          localScanAudioCandidates: 0,
          localScanReadFailures: 0,
        ),
      );

      // An empty folder completed cleanly: status ok, no error line.
      expect(report, contains('Local scan status: ok'));
      expect(report, isNot(contains('Local scan error:')));
    });

    test('reports the last scan error kind when present', () {
      final String report = AppDiagnostics.report(
        const AppDiagnosticsData(
          appVersion: '0.1.0',
          localScanError: 'safTraversal',
        ),
      );

      expect(report, contains('Local scan error: safTraversal'));
    });

    test('omits the local-scan lines when the fields are absent', () {
      final String report =
          AppDiagnostics.report(const AppDiagnosticsData(appVersion: '0.1.0'));

      expect(report, isNot(contains('Local folder:')));
      expect(report, isNot(contains('Local folder access:')));
      expect(report, isNot(contains('Local scan:')));
      expect(report, isNot(contains('Local scan error:')));
    });

    test('the local-scan lines carry no path, URI, or file name', () {
      final String report = AppDiagnostics.report(
        const AppDiagnosticsData(
          appVersion: '0.1.0',
          localFolderSelected: true,
          localPersistedPermission: false,
          localScanFilesVisited: 3,
          localScanAudioCandidates: 1,
          localScanSkippedUnsupported: 2,
          localScanReadFailures: 1,
          localScanError: 'safTraversal',
        ),
      );

      expect(report.toLowerCase(), isNot(contains('content://')));
      expect(report, isNot(contains('/storage/')));
      expect(report.toLowerCase(), isNot(contains('.mp3')));
      expect(report.toLowerCase(), isNot(contains('http')));
    });
  });
}
