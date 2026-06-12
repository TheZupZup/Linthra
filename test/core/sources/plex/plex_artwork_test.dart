import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/sources/plex/plex_artwork.dart';
import 'package:linthra/core/sources/plex/plex_track_mapper.dart';

const _session = PlexSession(
  baseUrl: 'https://plex.example.com:32400',
  token: 'the-secret-token',
  machineIdentifier: 'machine-1',
);

/// The credential-free reference the mapper persists for a thumb path, built
/// the same way `PlexTrackMapper` builds `Track.artworkUri`.
Uri _reference(String thumbPath) =>
    Uri(scheme: PlexTrackMapper.artworkScheme, path: thumbPath);

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
