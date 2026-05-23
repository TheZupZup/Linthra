import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_server_url.dart';

void main() {
  group('JellyfinServerUrl.normalize', () {
    test('defaults a bare host to https (the Cloudflare-proxied case)', () {
      expect(
        JellyfinServerUrl.normalize('music.example.com'),
        'https://music.example.com',
      );
    });

    test('keeps an explicit http scheme (local network)', () {
      expect(
        JellyfinServerUrl.normalize('http://localhost:8096'),
        'http://localhost:8096',
      );
    });

    test('preserves a port', () {
      expect(
        JellyfinServerUrl.normalize('https://music.example.com:8920'),
        'https://music.example.com:8920',
      );
    });

    test('preserves a reverse-proxy subpath', () {
      expect(
        JellyfinServerUrl.normalize('https://example.com/jellyfin'),
        'https://example.com/jellyfin',
      );
    });

    test('strips a trailing slash', () {
      expect(
        JellyfinServerUrl.normalize('https://example.com/jellyfin/'),
        'https://example.com/jellyfin',
      );
    });

    test('drops query and fragment', () {
      expect(
        JellyfinServerUrl.normalize('https://example.com/path?a=1#frag'),
        'https://example.com/path',
      );
    });

    test('trims surrounding whitespace', () {
      expect(
        JellyfinServerUrl.normalize('  music.example.com  '),
        'https://music.example.com',
      );
    });

    test('lowercases the host', () {
      expect(
        JellyfinServerUrl.normalize('https://Music.Example.COM'),
        'https://music.example.com',
      );
    });

    test('rejects an empty address', () {
      expect(
        () => JellyfinServerUrl.normalize('   '),
        throwsA(
          isA<JellyfinException>().having(
            (JellyfinException e) => e.kind,
            'kind',
            JellyfinErrorKind.invalidUrl,
          ),
        ),
      );
    });

    test('rejects a non-http(s) scheme', () {
      expect(
        () => JellyfinServerUrl.normalize('ftp://example.com'),
        throwsA(isA<JellyfinException>()),
      );
    });

    test('rejects a scheme with no host', () {
      expect(
        () => JellyfinServerUrl.normalize('https://'),
        throwsA(isA<JellyfinException>()),
      );
    });
  });

  group('JellyfinServerUrl.tryNormalize', () {
    test('returns the normalized URL when valid', () {
      expect(
        JellyfinServerUrl.tryNormalize('example.com'),
        'https://example.com',
      );
    });

    test('returns null when invalid instead of throwing', () {
      expect(JellyfinServerUrl.tryNormalize('   '), isNull);
      expect(JellyfinServerUrl.tryNormalize('ftp://x'), isNull);
    });
  });
}
