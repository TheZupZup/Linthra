import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/diagnostics/app_diagnostics.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_diagnostics.dart';

// These are what put a server address into a copyable diagnostics report, so
// they are the last line between a credential-bearing address and the
// clipboard. The full-URL cases are covered next to each one; these pin the
// shapes that take a different path through the code:
// AppDiagnostics.describeServer's scheme-less fallback (re-parsed as
// `//<value>`), where userinfo and a Subsonic query could otherwise ride
// along, and JellyfinDiagnostics.hostOnly given a URL with both userinfo and
// an ApiKey.

void main() {
  group('AppDiagnostics.describeServer on a scheme-less address', () {
    test('describes the address without its user:password@ or host', () {
      final String? description =
          AppDiagnostics.describeServer('alice:hunter2@music.example.com:8096');

      expect(
        description,
        'unknown scheme, unknown network (hostname), custom port',
      );
      expect(description, isNot(contains('alice')));
      expect(description, isNot(contains('hunter2')));
      expect(description, isNot(contains('music.example.com')));
      expect(description, isNot(contains('@')));
    });

    test('a bare user name is dropped too', () {
      expect(
        AppDiagnostics.describeServer('alice@192.168.1.10'),
        'unknown scheme, local network, default port',
      );
    });

    test('a path and a Subsonic credential query are dropped', () {
      final String? description = AppDiagnostics.describeServer(
          'music.example.com:8096/rest?t=tok&s=salt');

      expect(
        description,
        'unknown scheme, unknown network (hostname), custom port',
      );
      expect(description, isNot(contains('tok')));
      expect(description, isNot(contains('salt')));
      expect(description, isNot(contains('rest')));
    });

    test('userinfo, path and query together leave only the description', () {
      final String? description = AppDiagnostics.describeServer(
        'alice:hunter2@10.0.0.7:4533/rest/ping.view'
        '?u=alice&t=tok&s=salt&p=enc:cGFzcw',
      );

      expect(description, 'unknown scheme, local network, custom port');
    });

    test('a password with a raw @ yields nothing rather than part of it', () {
      // The parser cannot split this, so nothing is reported, which is safe;
      // what must not happen is any of `ss@music.example.com` reaching the
      // report.
      expect(
        AppDiagnostics.describeServer('alice:p@ss@music.example.com:8096'),
        isNull,
      );
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
      // Unlike AppDiagnostics.describeServer this has no scheme-less
      // fallback, so `alice:hunter2@…` parses with `alice` as its scheme and
      // an empty host.
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
