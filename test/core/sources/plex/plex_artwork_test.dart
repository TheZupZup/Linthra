import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/sources/plex/plex_api.dart';
import 'package:linthra/core/sources/plex/plex_artwork.dart';
import 'package:linthra/core/sources/plex/plex_track_mapper.dart';

const _session = PlexSession(
  baseUrl: 'https://plex.example.com:32400',
  token: 'the-secret-token',
  machineIdentifier: 'machine-1',
);

/// The credential-free reference the mapper persists for a thumb path, built
/// the same way `PlexTrackMapper` builds `Track.artworkUri` (literal `%`
/// pre-escaped so the stored form carries exactly one encoding level).
Uri _reference(String thumbPath) => Uri(
      scheme: PlexTrackMapper.artworkScheme,
      path: thumbPath.replaceAll('%', '%25'),
    );

void main() {
  group('PlexArtwork.resolve', () {
    test('weaves the session token into a cover-art URL at render time', () {
      final Uri? resolved = PlexArtwork.resolve(
        _reference('/library/metadata/123/thumb/1670000000'),
        _session,
      );

      expect(resolved, isNotNull);
      expect(resolved!.host, 'plex.example.com');
      expect(resolved.port, 32400);
      expect(resolved.path, '/library/metadata/123/thumb/1670000000');
      expect(resolved.queryParameters['X-Plex-Token'], 'the-secret-token');
    });

    test('a size scales the cover for the media session via the transcoder',
        () {
      // Mirrors SubsonicArtwork.resolve(size:): the media-session cache asks for
      // a small, fast-to-decode cover, so a plain thumb resolves to a photo-
      // transcode URL at the requested size — keeping Plex's media-session art
      // the same modest size as Subsonic's, not a full-resolution bitmap.
      final Uri? resolved = PlexArtwork.resolve(
        _reference('/library/metadata/123/thumb/1670000000'),
        _session,
        size: 512,
      );

      expect(resolved, isNotNull);
      expect(resolved!.host, 'plex.example.com');
      expect(resolved.port, 32400);
      expect(resolved.path, '/photo/:/transcode');
      expect(resolved.queryParameters['url'],
          '/library/metadata/123/thumb/1670000000');
      expect(resolved.queryParameters['width'], '512');
      expect(resolved.queryParameters['X-Plex-Token'], 'the-secret-token');
    });

    test('keeps the token in the query only, never in the path', () {
      final Uri resolved = PlexArtwork.resolve(
        _reference('/library/metadata/123/thumb/1'),
        _session,
      )!;
      expect(resolved.path, isNot(contains('the-secret-token')));
    });

    test('returns null for a non-Plex reference so other covers pass through',
        () {
      // A Jellyfin already-loadable http URL must not be rewritten.
      expect(
        PlexArtwork.resolve(
          Uri.parse('https://server.example/Items/1/Images/Primary'),
          _session,
        ),
        isNull,
      );
      // A local file cover is not a Plex reference.
      expect(
        PlexArtwork.resolve(Uri.parse('file:///cache/art/abc.img'), _session),
        isNull,
      );
      // A Subsonic cover reference belongs to the Subsonic resolver.
      expect(
        PlexArtwork.resolve(Uri.parse('subsonic-cover:al-123'), _session),
        isNull,
      );
      // The plex: *track* scheme is deliberately distinct from the artwork
      // reference scheme and must not resolve as a cover.
      expect(PlexArtwork.resolve(Uri.parse('plex:101'), _session), isNull);
    });

    test('returns null for an empty reference', () {
      expect(
        PlexArtwork.resolve(Uri.parse('plex-thumb:'), _session),
        isNull,
      );
    });

    test('resolves a sizing-transcoder reference with its query intact', () {
      // The reference a mapper built for a query-carrying thumb: the encoded
      // `?` must come back out as a real query — with the token merged in,
      // not replacing the transcoder's own params.
      final Uri reference = _reference(
        '/photo/:/transcode?url=/library/metadata/123/thumb/167&width=200',
      );

      final Uri? resolved = PlexArtwork.resolve(reference, _session);

      expect(resolved, isNotNull);
      expect(resolved!.path, '/photo/:/transcode');
      expect(
          resolved.queryParameters['url'], '/library/metadata/123/thumb/167');
      expect(resolved.queryParameters['width'], '200');
      expect(resolved.queryParameters['X-Plex-Token'], _session.token);
    });

    test(
        'resolves a transcoder reference whose url value PMS pre-encoded, '
        'end to end', () {
      // Built by the real mapper from the wire thumb, persisted, re-parsed,
      // and resolved — the inner encoding must reach the final URL untouched:
      // no decode/re-encode may promote the url value's `&b=2` to a top-level
      // param or truncate the inner URL the transcoder fetches.
      const String nestedThumb = '/photo/:/transcode'
          '?url=http%3A%2F%2Fhost%2Fcover%3Fa%3D1%26b%3D2&width=200';
      const PlexMetadata item =
          PlexMetadata(ratingKey: '7', title: 't', thumb: nestedThumb);
      final Uri persisted =
          Uri.parse(PlexTrackMapper.toTrack(item).artworkUri!.toString());

      final Uri? resolved = PlexArtwork.resolve(persisted, _session);

      expect(resolved, isNotNull);
      expect(resolved!.path, '/photo/:/transcode');
      expect(resolved.query,
          contains('url=http%3A%2F%2Fhost%2Fcover%3Fa%3D1%26b%3D2'));
      expect(resolved.queryParameters.containsKey('b'), isFalse);
      expect(resolved.queryParameters['url'], 'http://host/cover?a=1&b=2');
      expect(resolved.queryParameters['width'], '200');
      expect(resolved.queryParameters['X-Plex-Token'], _session.token);
    });

    test('a degenerate session (blank address or token) never resolves', () {
      // "Resolves only with a valid session": a session missing either half
      // can't mint a sound URL, so the reference keeps its placeholder.
      final Uri reference = _reference('/library/metadata/123/thumb/1');
      const PlexSession noToken = PlexSession(
        baseUrl: 'https://plex.example.com:32400',
        token: '',
        machineIdentifier: 'machine-1',
      );
      const PlexSession noServer = PlexSession(
        baseUrl: '',
        token: 'the-secret-token',
        machineIdentifier: 'machine-1',
      );
      expect(PlexArtwork.resolve(reference, noToken), isNull);
      expect(PlexArtwork.resolve(reference, noServer), isNull);
    });

    test('a thumb path that is not server-absolute never resolves', () {
      // Joined as-is it would splice into the base URL's authority and point
      // somewhere else entirely; fall back to the placeholder instead.
      expect(
        PlexArtwork.resolve(Uri.parse('plex-thumb:thumb.jpg'), _session),
        isNull,
      );
    });

    test('a reference smuggling a token-named param cannot keep it', () {
      // Defense in depth: a stored reference is credential-free by
      // construction, but even a hand-crafted one carrying its own
      // X-Plex-Token must come out with the live session's token only.
      final Uri reference = Uri(
        scheme: PlexTrackMapper.artworkScheme,
        path: '/photo/:/transcode?X-Plex-Token=stale-leaked&width=200',
      );

      final Uri? resolved = PlexArtwork.resolve(reference, _session);

      expect(resolved, isNotNull);
      expect(resolved.toString(), isNot(contains('stale-leaked')));
      expect(resolved!.queryParameters['X-Plex-Token'], _session.token);
    });

    test('never throws, whatever the reference carries', () {
      // The resolver runs synchronously inside widget builds; any failure
      // must degrade to the placeholder, never take down the frame.
      final List<Uri> hostile = <Uri>[
        Uri.parse('plex-thumb:'),
        Uri.parse('plex-thumb:no-leading-slash'),
        Uri.parse('plex-thumb:/thumb/100%zz'), // malformed escape, normalized
        Uri.parse('plex-thumb://host-looking/path'),
        Uri(scheme: 'plex-thumb', path: r'/a b/¿?#[]@!$&()*+,;=%.jpg'),
      ];
      for (final Uri reference in hostile) {
        expect(() => PlexArtwork.resolve(reference, _session), returnsNormally,
            reason: '$reference must not throw');
      }
    });

    test('the persisted reference itself stays credential-free', () {
      // The reference is what the catalog stores; the token and server address
      // are woven in only by resolve(), never persisted.
      final String reference =
          _reference('/library/metadata/123/thumb/1').toString();
      expect(reference, isNot(contains(_session.token)));
      expect(reference, isNot(contains(_session.baseUrl)));
      expect(reference, isNot(contains('plex.example.com')));
      expect(reference, isNot(contains('http')));
    });
  });
}
