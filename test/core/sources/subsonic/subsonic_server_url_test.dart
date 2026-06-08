import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/subsonic/subsonic_exception.dart';
import 'package:linthra/core/sources/subsonic/subsonic_server_url.dart';

void main() {
  group('SubsonicServerUrl.normalize', () {
    test('defaults a bare host to https', () {
      expect(
        SubsonicServerUrl.normalize('music.example.com'),
        'https://music.example.com',
      );
    });

    test('keeps an explicit http scheme (local network)', () {
      expect(
        SubsonicServerUrl.normalize('http://192.168.1.10:4533'),
        'http://192.168.1.10:4533',
      );
    });

    test('preserves a reverse-proxy subpath', () {
      expect(
        SubsonicServerUrl.normalize('https://example.com/navidrome'),
        'https://example.com/navidrome',
      );
    });

    test('strips a trailing slash, query, and fragment', () {
      expect(
        SubsonicServerUrl.normalize('https://music.example.com/?x=1#y'),
        'https://music.example.com',
      );
    });

    test('keeps a non-default port', () {
      expect(
        SubsonicServerUrl.normalize('music.example.com:4533'),
        'https://music.example.com:4533',
      );
    });

    test('normalizes the task example (LAN root, no /rest needed)', () {
      // Linthra appends /rest/<method>.view itself, so the user types the root.
      expect(
        SubsonicServerUrl.normalize('http://192.168.1.50:4533'),
        'http://192.168.1.50:4533',
      );
    });

    test('strips a trailing /rest the user pasted by mistake', () {
      // Linthra appends /rest itself; keeping it would double to /rest/rest/…
      expect(
        SubsonicServerUrl.normalize('http://192.168.1.50:4533/rest'),
        'http://192.168.1.50:4533',
      );
    });

    test('strips a trailing /rest/ (with slash) too', () {
      expect(
        SubsonicServerUrl.normalize('https://music.example.com/rest/'),
        'https://music.example.com',
      );
    });

    test('strips /rest while preserving a reverse-proxy subpath', () {
      expect(
        SubsonicServerUrl.normalize('https://example.com/navidrome/rest'),
        'https://example.com/navidrome',
      );
    });

    test('does not strip a subpath that merely ends in "rest"', () {
      // Only a whole final segment named "rest" is removed, not "…rest".
      expect(
        SubsonicServerUrl.normalize('https://example.com/myrest'),
        'https://example.com/myrest',
      );
    });

    test('trims surrounding whitespace', () {
      expect(
        SubsonicServerUrl.normalize('  music.example.com  '),
        'https://music.example.com',
      );
    });

    test('rejects an empty address', () {
      expect(
        () => SubsonicServerUrl.normalize('   '),
        throwsA(isA<SubsonicException>()
            .having((e) => e.kind, 'kind', SubsonicErrorKind.invalidUrl)),
      );
    });

    test('rejects a non-http scheme', () {
      expect(
        () => SubsonicServerUrl.normalize('ftp://music.example.com'),
        throwsA(isA<SubsonicException>()
            .having((e) => e.kind, 'kind', SubsonicErrorKind.invalidUrl)),
      );
    });

    test('tryNormalize returns null instead of throwing', () {
      expect(SubsonicServerUrl.tryNormalize(''), isNull);
      expect(
        SubsonicServerUrl.tryNormalize('music.example.com'),
        'https://music.example.com',
      );
    });
  });
}
