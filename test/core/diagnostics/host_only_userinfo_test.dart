import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/diagnostics/app_diagnostics.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_diagnostics.dart';

// The two host reducers are what put a server address into a copyable
// diagnostics report, so they are the last line between a credential-bearing
// address and the clipboard. The full-URL cases are covered next to each
// reducer; these pin the shapes that take a different path through the code:
// AppDiagnostics.hostOnly's scheme-less fallback (re-parsed as `//<value>`),
// where userinfo and a Subsonic query could otherwise ride along, and
// JellyfinDiagnostics.hostOnly given a URL with both userinfo and an ApiKey.

void main() {
  group('AppDiagnostics.hostOnly on a scheme-less address', () {
    test('drops user:password@ and keeps the host and port', () {
      final String? host =
          AppDiagnostics.hostOnly('alice:hunter2@music.example.com:8096');

      expect(host, 'music.example.com:8096');
      expect(host, isNot(contains('alice')));
      expect(host, isNot(contains('hunter2')));
      expect(host, isNot(contains('@')));
    });

    test('drops a bare user name too', () {
      expect(
        AppDiagnostics.hostOnly('alice@music.example.com'),
        'music.example.com',
      );
    });

    test('drops a path and a Subsonic credential query', () {
      final String? host =
          AppDiagnostics.hostOnly('music.example.com:8096/rest?t=tok&s=salt');

      expect(host, 'music.example.com:8096');
      expect(host, isNot(contains('tok')));
      expect(host, isNot(contains('salt')));
      expect(host, isNot(contains('rest')));
    });

    test('userinfo, path and query together reduce to the host alone', () {
      final String? host = AppDiagnostics.hostOnly(
        'alice:hunter2@music.example.com:4533/rest/ping.view'
        '?u=alice&t=tok&s=salt&p=enc:cGFzcw',
      );

      expect(host, 'music.example.com:4533');
    });

    test('a password with a raw @ yields no host rather than part of it', () {
      // The parser cannot split this, so nothing is reported, which is safe;
      // what must not happen is `ss@music.example.com` reaching the report.
      final String? host =
          AppDiagnostics.hostOnly('alice:p@ss@music.example.com:8096');

      expect(host, isNull);
    });
  });

  group('JellyfinDiagnostics.hostOnly with userinfo', () {
    test('drops user:password@ and the ApiKey', () {
      expect(JellyfinDiagnostics.hostOnly('https://u:pw@h/x?ApiKey=s'), 'h');

      final String? host = JellyfinDiagnostics.hostOnly(
        'https://alice:pw-secret@music.example.com:8920/jf/Audio/t1/stream'
        '?ApiKey=key-secret',
      );
      expect(host, 'music.example.com:8920');
      expect(host, isNot(contains('alice')));
      expect(host, isNot(contains('pw-secret')));
      expect(host, isNot(contains('key-secret')));
      expect(host, isNot(contains('ApiKey')));
    });

    test(
        'a scheme-less address with userinfo reports no host, not the userinfo',
        () {
      // Unlike AppDiagnostics.hostOnly this has no scheme-less fallback, so
      // `alice:hunter2@…` parses with `alice` as its scheme and an empty host.
      expect(
        JellyfinDiagnostics.hostOnly('alice:hunter2@music.example.com:8096'),
        isNull,
      );
    });

    test('the rendered report carries neither the password nor the key', () {
      final String report = JellyfinDiagnostics.describe(
        appVersion: '0.1.0',
        connectionState: 'connected',
        serverHost: JellyfinDiagnostics.hostOnly(
          'https://alice:pw-secret@music.example.com/Audio/t1/stream'
          '?ApiKey=key-secret',
        ),
      );

      expect(report, contains('Server host: music.example.com'));
      expect(report, isNot(contains('alice')));
      expect(report, isNot(contains('pw-secret')));
      expect(report, isNot(contains('key-secret')));
    });
  });
}
