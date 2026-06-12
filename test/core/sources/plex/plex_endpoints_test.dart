import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/plex/plex_api.dart';
import 'package:linthra/core/sources/plex/plex_endpoints.dart';

const String _base = 'https://plex.example.com:32400';
const String _token = 'super-secret-plex-token';

void main() {
  group('PlexEndpoints builds the API paths internally', () {
    test('identity targets /identity', () {
      expect(PlexEndpoints.identity(_base).path, '/identity');
    });

    test('librarySections targets /library/sections', () {
      expect(PlexEndpoints.librarySections(_base).path, '/library/sections');
    });

    test('metadata carries the ratingKey in the path', () {
      final Uri uri = PlexEndpoints.metadata(_base, ratingKey: '1234');
      expect(uri.path, '/library/metadata/1234');
    });

    test('preserves a reverse-proxy subpath ahead of the API path', () {
      final Uri uri = PlexEndpoints.identity('https://example.com/plex');
      expect(uri.path, '/plex/identity');
    });
  });

  group('PlexEndpoints.sectionItems selects the music type', () {
    test('artists request type=8 on /library/sections/{key}/all', () {
      final Uri uri = PlexEndpoints.sectionItems(
        _base,
        sectionKey: '3',
        itemType: PlexMetadataType.artist,
      );
      expect(uri.path, '/library/sections/3/all');
      expect(uri.queryParameters[PlexEndpoints.typeParam], '8');
    });

    test('albums request type=9', () {
      final Uri uri = PlexEndpoints.sectionItems(
        _base,
        sectionKey: '3',
        itemType: PlexMetadataType.album,
      );
      expect(uri.path, '/library/sections/3/all');
      expect(uri.queryParameters[PlexEndpoints.typeParam], '9');
    });

    test('tracks request type=10', () {
      final Uri uri = PlexEndpoints.sectionItems(
        _base,
        sectionKey: '3',
        itemType: PlexMetadataType.track,
      );
      expect(uri.path, '/library/sections/3/all');
      expect(uri.queryParameters[PlexEndpoints.typeParam], '10');
    });

    test('omits the pagination params when no start/size is given', () {
      final Uri uri = PlexEndpoints.sectionItems(
        _base,
        sectionKey: '3',
        itemType: PlexMetadataType.track,
      );
      expect(uri.queryParameters.containsKey(PlexEndpoints.containerStartParam),
          isFalse);
      expect(uri.queryParameters.containsKey(PlexEndpoints.containerSizeParam),
          isFalse);
    });

    test('adds X-Plex-Container-Start / -Size to page a large library', () {
      final Uri uri = PlexEndpoints.sectionItems(
        _base,
        sectionKey: '3',
        itemType: PlexMetadataType.track,
        start: 500,
        size: 100,
      );
      expect(uri.queryParameters[PlexEndpoints.containerStartParam], '500');
      expect(uri.queryParameters[PlexEndpoints.containerSizeParam], '100');
      // The type selector survives alongside the paging params.
      expect(uri.queryParameters[PlexEndpoints.typeParam], '10');
    });

    test('the named pagination keys are exactly the PMS header/query names',
        () {
      expect(PlexEndpoints.containerStartParam, 'X-Plex-Container-Start');
      expect(PlexEndpoints.containerSizeParam, 'X-Plex-Container-Size');
    });
  });

  group('PlexEndpoints API calls carry NO token (it rides in a header)', () {
    test('identity / sections / items / metadata URLs are token-free', () {
      final List<Uri> apiUrls = <Uri>[
        PlexEndpoints.identity(_base),
        PlexEndpoints.librarySections(_base),
        PlexEndpoints.sectionItems(
          _base,
          sectionKey: '3',
          itemType: PlexMetadataType.album,
          start: 0,
          size: 50,
        ),
        PlexEndpoints.metadata(_base, ratingKey: '1234'),
      ];
      for (final Uri uri in apiUrls) {
        expect(
            uri.queryParameters.containsKey(PlexEndpoints.tokenParam), isFalse,
            reason: '$uri must not carry the token in its query');
        expect(uri.toString().toLowerCase(), isNot(contains('x-plex-token')),
            reason: '$uri must be safe to log');
      }
    });
  });

  group('PlexEndpoints.streamUrl (Part key + token in the query)', () {
    const String partKey = '/library/parts/12345/167/file.flac';

    test('appends the server-absolute Part key to the base URL', () {
      final Uri uri =
          PlexEndpoints.streamUrl(_base, partKey: partKey, token: _token);
      expect(uri.path, '/library/parts/12345/167/file.flac');
      expect(uri.host, 'plex.example.com');
      expect(uri.port, 32400);
    });

    test('weaves the token into the query — never the path', () {
      final Uri uri =
          PlexEndpoints.streamUrl(_base, partKey: partKey, token: _token);
      expect(uri.queryParameters[PlexEndpoints.tokenParam], _token);
      expect(uri.path, isNot(contains(_token)));
    });

    test('preserves a query the Part key already carried', () {
      // A Part key is normally a plain path, but adding the token must merge
      // into — not replace — any query, so an unusual key survives intact.
      final Uri uri = PlexEndpoints.streamUrl(
        _base,
        partKey: '/library/parts/12345/167/file.flac?download=1',
        token: _token,
      );
      expect(uri.path, '/library/parts/12345/167/file.flac');
      expect(uri.queryParameters['download'], '1');
      expect(uri.queryParameters[PlexEndpoints.tokenParam], _token);
    });
  });

  group('PlexEndpoints.coverArt (thumb path + token in the query)', () {
    const String thumb = '/library/metadata/123/thumb/1670000000';

    test('appends the thumb path and weaves the token into the query', () {
      final Uri uri =
          PlexEndpoints.coverArt(_base, thumbPath: thumb, token: _token);
      expect(uri.path, '/library/metadata/123/thumb/1670000000');
      expect(uri.queryParameters[PlexEndpoints.tokenParam], _token);
      // The image URL is fetched plainly, so the token must ride in the query
      // exactly like the stream URL — and never in the path.
      expect(uri.path, isNot(contains(_token)));
    });

    test('preserves the query of a sizing-transcoder thumb path', () {
      // Some items report their art as a photo-transcoder path whose query
      // *is* the request (`url`, `width`, …). Weaving the token in must keep
      // those params — replacing the whole query would break the image.
      final Uri uri = PlexEndpoints.coverArt(
        _base,
        thumbPath:
            '/photo/:/transcode?url=/library/metadata/123/thumb/167&width=200',
        token: _token,
      );
      expect(uri.path, '/photo/:/transcode');
      expect(uri.queryParameters['url'], '/library/metadata/123/thumb/167');
      expect(uri.queryParameters['width'], '200');
      expect(uri.queryParameters[PlexEndpoints.tokenParam], _token);
    });

    test('splices an encoded transcoder url value through byte-for-byte', () {
      // A transcoder's `url=` value is itself percent-encoded; weaving the
      // token in must not decode and re-encode it (the inner `%26` would
      // become a real `&`, promoting `b=2` to a top-level param and handing
      // the transcoder a truncated url).
      final Uri uri = PlexEndpoints.coverArt(
        _base,
        thumbPath: '/photo/:/transcode'
            '?url=http%3A%2F%2Fhost%2Fcover%3Fa%3D1%26b%3D2&width=200',
        token: _token,
      );
      // The raw query still carries the value exactly as the server wrote it.
      expect(
          uri.query, contains('url=http%3A%2F%2Fhost%2Fcover%3Fa%3D1%26b%3D2'));
      expect(uri.queryParameters.containsKey('b'), isFalse);
      // The server decodes the full inner URL back out, query intact.
      expect(uri.queryParameters['url'], 'http://host/cover?a=1&b=2');
      expect(uri.queryParameters['width'], '200');
      expect(uri.queryParameters[PlexEndpoints.tokenParam], _token);
    });

    test('never rewrites the encoding of untouched query pairs', () {
      // `%20` and `+` both read as a space, but they are different bytes; the
      // weave must pass pairs through raw, not normalize one to the other.
      final Uri uri = PlexEndpoints.coverArt(
        _base,
        thumbPath: '/photo/:/transcode?url=a%20b&width=200',
        token: _token,
      );
      expect(uri.query, contains('url=a%20b'));
      expect(uri.query, isNot(contains('url=a+b')));
    });

    test('a token-named param smuggled in the path is replaced, never kept',
        () {
      // The live session's token is the only credential allowed into a minted
      // URL: a stored path carrying its own X-Plex-Token (however cased or
      // with its name percent-encoded) must not survive — neither pinning a
      // stale token nor doubling the param.
      for (final String smuggled in <String>[
        '/photo/:/transcode?x-plex-token=stale-leaked&width=200',
        '/photo/:/transcode?X%2DPlex%2DToken=stale-leaked&width=200',
      ]) {
        final Uri uri = PlexEndpoints.coverArt(
          _base,
          thumbPath: smuggled,
          token: _token,
        );
        expect(uri.queryParameters[PlexEndpoints.tokenParam], _token,
            reason: '$smuggled must carry the live token');
        expect(uri.toString(), isNot(contains('stale-leaked')),
            reason: '$smuggled must not keep the smuggled value');
        expect(uri.queryParameters['width'], '200');
        // Exactly one token param remains.
        expect(
          RegExp('x-plex-token', caseSensitive: false)
              .allMatches(Uri.decodeFull(uri.toString()))
              .length,
          1,
          reason: '$smuggled must yield exactly one token param',
        );
      }
    });
  });

  group('PlexEndpoints.redactToken guards URL/log lines', () {
    test('redacts the token in a stream URL', () {
      final String url =
          PlexEndpoints.streamUrl(_base, partKey: '/p/1', token: _token)
              .toString();
      final String redacted = PlexEndpoints.redactToken(url);
      expect(redacted, isNot(contains(_token)));
      expect(redacted, contains('X-Plex-Token=<redacted>'));
    });

    test('redacts the token mid-query without eating later params', () {
      const String line =
          'GET /p/1?X-Plex-Token=$_token&X-Plex-Container-Size=50 200';
      final String redacted = PlexEndpoints.redactToken(line);
      expect(redacted, isNot(contains(_token)));
      expect(redacted, contains('X-Plex-Token=<redacted>'));
      // The value stops at the '&' so the following param survives intact.
      expect(redacted, contains('X-Plex-Container-Size=50'));
    });

    test('redacts a token that appears before a fragment', () {
      const String line = 'https://h/p?X-Plex-Token=$_token#frag';
      final String redacted = PlexEndpoints.redactToken(line);
      expect(redacted, isNot(contains(_token)));
      expect(redacted, contains('#frag'));
    });

    test('matches the parameter name case-insensitively', () {
      const String line = 'https://h/p?x-plex-token=$_token';
      expect(PlexEndpoints.redactToken(line), isNot(contains(_token)));
    });

    test('leaves a token-free line untouched', () {
      const String line = 'GET /library/sections 200';
      expect(PlexEndpoints.redactToken(line), line);
    });
  });
}
