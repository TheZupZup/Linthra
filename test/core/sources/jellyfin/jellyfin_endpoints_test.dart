import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_endpoints.dart';

const String _base = 'https://music.example.com';
const String _token = 'super-secret-token';

void main() {
  group('JellyfinEndpoints unauthenticated paths', () {
    test('serverInfo targets the public info endpoint', () {
      expect(JellyfinEndpoints.serverInfo(_base).path, '/System/Info/Public');
    });

    test('authenticateByName targets the auth endpoint', () {
      expect(JellyfinEndpoints.authenticateByName(_base).path,
          '/Users/AuthenticateByName');
    });

    test('currentUser targets /Users/Me', () {
      expect(JellyfinEndpoints.currentUser(_base).path, '/Users/Me');
    });

    test('preserves a reverse-proxy subpath on the base URL', () {
      // A server mounted under a subpath must keep it on every endpoint.
      final Uri uri =
          JellyfinEndpoints.serverInfo('https://example.com/jellyfin');
      expect(uri.path, '/jellyfin/System/Info/Public');
    });
  });

  group('JellyfinEndpoints.items', () {
    test('audio lists from /Items filtered to Audio with the user id', () {
      final Uri uri = JellyfinEndpoints.items(
        _base,
        userId: 'user-1',
        kind: JellyfinItemKind.audio,
      );
      expect(uri.path, '/Items');
      expect(uri.queryParameters['IncludeItemTypes'], 'Audio');
      expect(uri.queryParameters['UserId'], 'user-1');
      expect(uri.queryParameters['Recursive'], 'true');
      expect(uri.queryParameters['Fields'], 'RunTimeTicks');
    });

    test('album lists MusicAlbum items', () {
      final Uri uri = JellyfinEndpoints.items(
        _base,
        userId: 'user-1',
        kind: JellyfinItemKind.album,
      );
      expect(uri.path, '/Items');
      expect(uri.queryParameters['IncludeItemTypes'], 'MusicAlbum');
    });

    test('artist uses the dedicated /Artists endpoint', () {
      final Uri uri = JellyfinEndpoints.items(
        _base,
        userId: 'user-1',
        kind: JellyfinItemKind.artist,
      );
      expect(uri.path, '/Artists');
      expect(uri.queryParameters['UserId'], 'user-1');
    });
  });

  group('JellyfinEndpoints favourites / lyrics / artwork', () {
    test('favoriteAudioItems filters to IsFavorite and disables images', () {
      final Uri uri =
          JellyfinEndpoints.favoriteAudioItems(_base, userId: 'user-1');
      expect(uri.path, '/Items');
      expect(uri.queryParameters['Filters'], 'IsFavorite');
      expect(uri.queryParameters['EnableImages'], 'false');
    });

    test('favoriteItem targets the per-user favourite item path', () {
      final Uri uri = JellyfinEndpoints.favoriteItem(
        _base,
        userId: 'user-1',
        itemId: 'item-7',
      );
      expect(uri.path, '/Users/user-1/FavoriteItems/item-7');
    });

    test('lyrics targets the audio lyrics endpoint', () {
      expect(
        JellyfinEndpoints.lyrics(_base, itemId: 'item-7').path,
        '/Audio/item-7/Lyrics',
      );
    });

    test('primaryImage is a token-free cover-art URL', () {
      final Uri uri = JellyfinEndpoints.primaryImage(_base, itemId: 'item-7');
      expect(uri.path, '/Items/item-7/Images/Primary');
      // Artwork needs no auth, so it carries no token (safe to persist/cache).
      expect(uri.toString(), isNot(contains('api_key')));
    });
  });

  group('JellyfinEndpoints playback reporting', () {
    test('start/progress/stop target the play-session endpoints', () {
      expect(
          JellyfinEndpoints.playbackStarted(_base).path, '/Sessions/Playing');
      expect(JellyfinEndpoints.playbackProgress(_base).path,
          '/Sessions/Playing/Progress');
      expect(JellyfinEndpoints.playbackStopped(_base).path,
          '/Sessions/Playing/Stopped');
    });

    test('the reporting URLs are token-free (item and auth ride elsewhere)',
        () {
      // The item/position go in the JSON body and the token in the
      // Authorization header, so these URLs carry nothing at all.
      for (final Uri uri in <Uri>[
        JellyfinEndpoints.playbackStarted(_base),
        JellyfinEndpoints.playbackProgress(_base),
        JellyfinEndpoints.playbackStopped(_base),
      ]) {
        expect(uri.hasQuery, isFalse);
      }
    });
  });

  group('JellyfinEndpoints.audioStream', () {
    final Uri uri = JellyfinEndpoints.audioStream(
      _base,
      itemId: 't1',
      accessToken: _token,
      userId: 'user-1',
      deviceId: 'device-1',
    );

    test('uses the direct-play stream endpoint with static=true', () {
      expect(uri.path, '/Audio/t1/stream');
      expect(uri.queryParameters['static'], 'true');
      expect(uri.queryParameters['UserId'], 'user-1');
      expect(uri.queryParameters['DeviceId'], 'device-1');
    });

    test('weaves the token into the api_key query, never the path', () {
      expect(uri.queryParameters['api_key'], _token);
      // The token is in the query only — never in the path the catalog/logs see.
      expect(uri.path, isNot(contains(_token)));
    });
  });

  group('JellyfinEndpoints.download', () {
    final Uri uri = JellyfinEndpoints.download(
      _base,
      itemId: 't1',
      accessToken: _token,
    );

    test('uses the original-file download endpoint', () {
      expect(uri.path, '/Items/t1/Download');
    });

    test('weaves the token into the api_key query, never the path', () {
      expect(uri.queryParameters['api_key'], _token);
      expect(uri.path, isNot(contains(_token)));
    });
  });
}
