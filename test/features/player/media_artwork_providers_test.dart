import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/sources/plex/plex_track_mapper.dart';
import 'package:linthra/core/sources/subsonic/subsonic_artwork.dart';
import 'package:linthra/features/player/media_artwork_providers.dart';

const _subsonic = SubsonicSession(
  baseUrl: 'https://music.example.com',
  username: 'alice',
  salt: 'the-salt',
  token: 'subsonic-secret-token',
);

const _plex = PlexSession(
  baseUrl: 'https://plex.example.com:32400',
  token: 'plex-secret-token',
  machineIdentifier: 'machine-1',
);

/// A credential-free Plex cover reference built exactly as `PlexTrackMapper`
/// builds `Track.artworkUri` (literal `%` pre-escaped), so the test exercises
/// the same value the catalog persists for a Plex track.
Uri _plexThumb(String thumbPath) => Uri(
      scheme: PlexTrackMapper.artworkScheme,
      path: thumbPath.replaceAll('%', '%25'),
    );

void main() {
  group('resolveMediaSessionArtworkUrl', () {
    // The regression this fixes: a Plex track's plex-thumb: cover reaching the
    // media session (lock screen / Android Auto). Before the fix the resolver
    // only knew Subsonic, so a Plex reference resolved to null, was never
    // fetched/cached, and the now-playing card showed no art.
    test('resolves a Plex reference at the media-session size', () {
      final Uri? resolved = resolveMediaSessionArtworkUrl(
        _plexThumb('/library/metadata/123/thumb/1670000000'),
        plex: _plex,
      );

      expect(resolved, isNotNull);
      expect(resolved!.host, 'plex.example.com');
      expect(resolved.port, 32400);
      // Like Subsonic, the media-session path asks PMS for a small, fast-to-
      // decode cover (via the photo transcoder) rather than the full-resolution
      // thumb — so the now-playing card stays crisp without a huge bitmap
      // crossing the process boundary, and the shared cache holds a modest file.
      expect(resolved.path, '/photo/:/transcode');
      expect(resolved.queryParameters['url'],
          '/library/metadata/123/thumb/1670000000');
      expect(resolved.queryParameters['width'], '$kMediaSessionArtworkSize');
      // The token rides in the query (the image layer can't set headers) — and
      // it is the live session's token, woven in on demand.
      expect(resolved.queryParameters['X-Plex-Token'], 'plex-secret-token');
    });

    test(
        'a Plex reference resolves even when a Subsonic session is also present',
        () {
      // Proves the providers chain: Subsonic returns null for a plex-thumb:
      // reference (it isn't a subsonic-cover:), so resolution falls through to
      // Plex rather than stopping at the first provider. This is exactly the
      // path that was missing before the fix.
      final Uri? resolved = resolveMediaSessionArtworkUrl(
        _plexThumb('/library/metadata/123/thumb/1'),
        subsonic: _subsonic,
        plex: _plex,
      );

      expect(resolved, isNotNull);
      expect(resolved!.host, 'plex.example.com');
      expect(resolved.queryParameters['X-Plex-Token'], 'plex-secret-token');
    });

    test('a Plex reference does not resolve when signed out of Plex', () {
      expect(
        resolveMediaSessionArtworkUrl(
          _plexThumb('/library/metadata/123/thumb/1'),
        ),
        isNull,
      );
    });

    test('resolves a Subsonic reference at the media-session size', () {
      final Uri? resolved = resolveMediaSessionArtworkUrl(
        SubsonicArtwork.reference('al-123'),
        subsonic: _subsonic,
      );

      expect(resolved, isNotNull);
      expect(resolved!.path, contains('getCoverArt'));
      expect(resolved.queryParameters['id'], 'al-123');
      // The media-session path asks the server for a small, fast-to-decode
      // cover (unlike the in-app full-size render), so the card stays crisp
      // without crossing the process boundary as a huge bitmap.
      expect(resolved.queryParameters['size'], '$kMediaSessionArtworkSize');
      expect(resolved.queryParameters['t'], 'subsonic-secret-token');
    });

    test('a Subsonic reference resolves to Subsonic even with a Plex session',
        () {
      // Subsonic owns its scheme and is tried first, so the Plex session is not
      // consulted for a subsonic-cover: reference.
      final Uri? resolved = resolveMediaSessionArtworkUrl(
        SubsonicArtwork.reference('al-123'),
        subsonic: _subsonic,
        plex: _plex,
      );

      expect(resolved, isNotNull);
      expect(resolved!.host, 'music.example.com');
      expect(resolved.toString(), isNot(contains('plex-secret-token')));
    });

    test('an already-loadable Jellyfin/local cover is left for direct loading',
        () {
      // A token-free http(s) image and a local file: cover are platform-
      // loadable and never reach this cache, so neither provider claims them.
      for (final Uri loadable in <Uri>[
        Uri.parse('https://server.example/Items/1/Images/Primary'),
        Uri.parse('file:///cache/art/abc.img'),
      ]) {
        expect(
          resolveMediaSessionArtworkUrl(
            loadable,
            subsonic: _subsonic,
            plex: _plex,
          ),
          isNull,
          reason: '$loadable must not be rewritten by a reference resolver',
        );
      }
    });

    test('no signed-in providers means no media-session artwork', () {
      expect(
        resolveMediaSessionArtworkUrl(
            _plexThumb('/library/metadata/1/thumb/1')),
        isNull,
      );
      expect(
        resolveMediaSessionArtworkUrl(SubsonicArtwork.reference('al-1')),
        isNull,
      );
    });
  });

  group('mediaSessionArtworkCacheKey', () {
    test('folds the media-session size into a Plex plex-thumb: identity', () {
      final Uri reference =
          _plexThumb('/library/metadata/123/thumb/1670000000');

      final Uri key = mediaSessionArtworkCacheKey(reference);

      // The size is tagged onto the cache key only, so a downscaled media-
      // session entry can never share a cache slot with a full-size cover.
      expect(key.queryParameters['mscover'], '$kMediaSessionArtworkSize');
      // The thumb path (the cover identity) is preserved...
      expect(key.path, '/library/metadata/123/thumb/1670000000');
      // ...and the size-tagged key differs from the bare reference.
      expect(key, isNot(reference));
    });

    test('leaves a Subsonic subsonic-cover: reference unchanged', () {
      // Subsonic fetches one constant media-session size, so its cache identity
      // (and on-disk entries) must be byte-for-byte unchanged.
      final Uri reference = SubsonicArtwork.reference('al-123');
      expect(mediaSessionArtworkCacheKey(reference), reference);
    });

    test('leaves an already-loadable Jellyfin/local cover unchanged', () {
      for (final Uri loadable in <Uri>[
        Uri.parse('https://server.example/Items/1/Images/Primary'),
        Uri.parse('file:///cache/art/abc.img'),
      ]) {
        expect(mediaSessionArtworkCacheKey(loadable), loadable);
      }
    });

    test('does not mutate the stored reference (in-app stays full size)', () {
      // The function returns a new keying identity; the stored Track.artworkUri
      // the in-app render resolves at full size is left untouched.
      final Uri reference = _plexThumb('/library/metadata/9/thumb/1');
      mediaSessionArtworkCacheKey(reference);
      expect(reference.queryParameters.containsKey('mscover'), isFalse);
    });
  });
}
