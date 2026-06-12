import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/plex/plex_tv_endpoints.dart';

void main() {
  group('pins', () {
    test('mints at /api/v2/pins with strong=true', () {
      final Uri url = PlexTvEndpoints.pins();
      expect(url.toString(), 'https://plex.tv/api/v2/pins?strong=true');
    });

    test('polls one pin by id', () {
      final Uri url = PlexTvEndpoints.pin(123456);
      expect(url.toString(), 'https://plex.tv/api/v2/pins/123456');
    });
  });

  group('resources', () {
    test('asks for https and relay addresses', () {
      final Uri url = PlexTvEndpoints.resources();
      expect(
        url.toString(),
        'https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1',
      );
    });
  });

  group('authApp', () {
    test('builds the hosted sign-in page with params in the fragment', () {
      final Uri url = PlexTvEndpoints.authApp(
        clientIdentifier: 'install-uuid-1',
        code: 'abc123DEF',
        product: 'Linthra',
      );

      // The exact canonical shape the hosted page parses: everything after
      // `#?`, with the context key percent-encoded.
      expect(
        url.toString(),
        'https://app.plex.tv/auth#?clientID=install-uuid-1&code=abc123DEF'
        '&context%5Bdevice%5D%5Bproduct%5D=Linthra',
      );
      // Fragment, not query: the params are read client-side by the page and
      // are never sent to a server in a request line.
      expect(url.query, isEmpty);
      expect(url.fragment, startsWith('?clientID='));
    });

    test('percent-encodes reserved characters in values', () {
      final Uri url = PlexTvEndpoints.authApp(
        clientIdentifier: 'id with space',
        code: 'co&de=+x',
        product: 'My Player',
      );

      final String text = url.toString();
      expect(text, contains('clientID=id%20with%20space'));
      expect(text, contains('code=co%26de%3D%2Bx'));
      expect(text, contains('context%5Bdevice%5D%5Bproduct%5D=My%20Player'));
    });

    test('never carries a token parameter', () {
      final Uri url = PlexTvEndpoints.authApp(
        clientIdentifier: 'cid',
        code: 'code',
        product: 'Linthra',
      );
      expect(url.toString().toLowerCase(), isNot(contains('x-plex-token')));
    });
  });
}
