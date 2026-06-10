import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/sources/subsonic/subsonic_artwork.dart';
import 'package:linthra/core/sources/subsonic/subsonic_endpoints.dart';

const _session = SubsonicSession(
  baseUrl: 'https://music.example.com',
  username: 'alice',
  salt: 'the-salt',
  token: 'the-secret-token',
);

void main() {
  group('SubsonicArtwork.reference', () {
    test('builds an opaque subsonic-cover: reference for a cover id', () {
      final Uri ref = SubsonicArtwork.reference('al-123');
      expect(ref.scheme, SubsonicArtwork.referenceScheme);
      expect(ref.scheme, 'subsonic-cover');
      expect(ref.toString(), 'subsonic-cover:al-123');
    });

    test('round-trips the cover id through coverArtId', () {
      for (final String id in <String>[
        'al-123',
        'ar-9e2a',
        'mf-7',
        '42',
        // Ids with characters that need URL-encoding still round-trip exactly.
        'cover with spaces',
        'a/b',
      ]) {
        final Uri ref = SubsonicArtwork.reference(id);
        expect(SubsonicArtwork.coverArtId(ref), id,
            reason: 'id "$id" must survive the reference round-trip');
      }
    });

    test('the reference is credential-free and carries no server URL', () {
      // The reference is persisted in the catalog, so it must never embed the
      // salt/token/username/password or the server address.
      final String ref = SubsonicArtwork.reference('al-123').toString();
      expect(ref, isNot(contains(_session.token)));
      expect(ref, isNot(contains(_session.salt)));
      expect(ref, isNot(contains(_session.username)));
      expect(ref, isNot(contains(_session.baseUrl)));
      expect(ref, isNot(contains('http')));
    });
  });

  group('SubsonicArtwork.coverArtId', () {
    test('returns null for a non-Subsonic-cover uri (passes through)', () {
      // A Jellyfin http(s) image URL and a local file: cover are not references
      // and must be left for the resolver to load directly.
      expect(
        SubsonicArtwork.coverArtId(
          Uri.parse('https://server.example/Items/1/Images/Primary'),
        ),
        isNull,
      );
      expect(
        SubsonicArtwork.coverArtId(Uri.parse('file:///cache/art/abc.img')),
        isNull,
      );
      // The track URI scheme (subsonic:) is deliberately distinct and not a
      // cover reference.
      expect(SubsonicArtwork.coverArtId(Uri.parse('subsonic:song-1')), isNull);
    });

    test('returns null for an empty reference', () {
      expect(SubsonicArtwork.coverArtId(Uri.parse('subsonic-cover:')), isNull);
    });
  });

  group('SubsonicArtwork.resolve', () {
    test('weaves the session credential into a getCoverArt URL', () {
      final Uri ref = SubsonicArtwork.reference('al-123');
      final Uri? resolved = SubsonicArtwork.resolve(ref, _session);

      expect(resolved, isNotNull);
      expect(resolved!.host, 'music.example.com');
      expect(resolved.path, '/rest/getCoverArt.view');
      final Map<String, String> q = resolved.queryParameters;
      expect(q['id'], 'al-123');
      expect(q['u'], 'alice');
      expect(q['t'], 'the-secret-token');
      expect(q['s'], 'the-salt');
      expect(q['v'], SubsonicEndpoints.apiVersion);
    });

    test('keeps the credential in the query only, never in the path', () {
      final Uri resolved =
          SubsonicArtwork.resolve(SubsonicArtwork.reference('al-1'), _session)!;
      expect(resolved.path, isNot(contains('the-secret-token')));
      expect(resolved.path, isNot(contains('the-salt')));
    });

    test('forwards a size so the media session gets a server-scaled cover', () {
      final Uri resolved = SubsonicArtwork.resolve(
        SubsonicArtwork.reference('al-1'),
        _session,
        size: 512,
      )!;
      expect(resolved.queryParameters['id'], 'al-1');
      expect(resolved.queryParameters['size'], '512');
      // Still credential-free in the path, exactly like the full-size resolve.
      expect(resolved.path, isNot(contains('the-secret-token')));
      expect(resolved.path, isNot(contains('the-salt')));
    });

    test('omits size by default (the in-app render stays full-size)', () {
      final Uri resolved =
          SubsonicArtwork.resolve(SubsonicArtwork.reference('al-1'), _session)!;
      expect(resolved.queryParameters.containsKey('size'), isFalse);
    });

    test('returns null for a non-reference uri so other covers pass through',
        () {
      // Jellyfin's already-loadable http URL must not be rewritten.
      final Uri jellyfin =
          Uri.parse('https://server.example/Items/1/Images/Primary');
      expect(SubsonicArtwork.resolve(jellyfin, _session), isNull);
      // A local file cover is likewise not a Subsonic reference.
      expect(
        SubsonicArtwork.resolve(
            Uri.parse('file:///cache/art/abc.img'), _session),
        isNull,
      );
    });
  });
}
