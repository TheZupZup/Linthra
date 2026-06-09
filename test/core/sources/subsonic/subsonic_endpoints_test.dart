import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/subsonic/subsonic_auth.dart';
import 'package:linthra/core/sources/subsonic/subsonic_endpoints.dart';

const String _base = 'https://music.example.com';
const String _user = 'alice';
const SubsonicCredentials _creds = SubsonicCredentials(
  salt: 'the-salt',
  token: 'the-secret-token',
);

void main() {
  group('SubsonicEndpoints builds the /rest API path internally', () {
    test('ping targets /rest/ping.view (user never types /rest)', () {
      final Uri uri =
          SubsonicEndpoints.ping(_base, username: _user, credentials: _creds);
      expect(uri.path, '/rest/ping.view');
    });

    test('getArtists targets /rest/getArtists.view', () {
      final Uri uri = SubsonicEndpoints.getArtists(
        _base,
        username: _user,
        credentials: _creds,
      );
      expect(uri.path, '/rest/getArtists.view');
    });

    test('getAlbumList2 carries the type, size and offset', () {
      final Uri uri = SubsonicEndpoints.getAlbumList2(
        _base,
        username: _user,
        credentials: _creds,
        size: 500,
        offset: 1000,
      );
      expect(uri.path, '/rest/getAlbumList2.view');
      expect(uri.queryParameters['type'], 'alphabeticalByName');
      expect(uri.queryParameters['size'], '500');
      expect(uri.queryParameters['offset'], '1000');
    });

    test('getAlbum carries the album id', () {
      final Uri uri = SubsonicEndpoints.getAlbum(
        _base,
        username: _user,
        credentials: _creds,
        albumId: 'al-1',
      );
      expect(uri.path, '/rest/getAlbum.view');
      expect(uri.queryParameters['id'], 'al-1');
    });

    test('stream and download carry the song id on their own endpoints', () {
      final Uri stream = SubsonicEndpoints.stream(
        _base,
        username: _user,
        credentials: _creds,
        songId: 's-7',
      );
      final Uri download = SubsonicEndpoints.download(
        _base,
        username: _user,
        credentials: _creds,
        songId: 's-7',
      );
      expect(stream.path, '/rest/stream.view');
      expect(download.path, '/rest/download.view');
      expect(stream.queryParameters['id'], 's-7');
      expect(download.queryParameters['id'], 's-7');
    });

    test('coverArt targets /rest/getCoverArt.view and carries the cover id',
        () {
      final Uri uri = SubsonicEndpoints.coverArt(
        _base,
        username: _user,
        credentials: _creds,
        coverArtId: 'al-123',
      );
      expect(uri.path, '/rest/getCoverArt.view');
      expect(uri.queryParameters['id'], 'al-123');
      // No size is requested, so the server serves the original art.
      expect(uri.queryParameters.containsKey('size'), isFalse);
    });

    test(
        'coverArt weaves the auth query and keeps the credential out of the '
        'path', () {
      final Uri uri = SubsonicEndpoints.coverArt(
        _base,
        username: _user,
        credentials: _creds,
        coverArtId: 'al-123',
      );
      // The image URL is fetched plainly (NetworkImage), so the salt+token must
      // ride in the query exactly like stream/download — and never in the path.
      final Map<String, String> q = uri.queryParameters;
      expect(q['u'], _user);
      expect(q['t'], _creds.token);
      expect(q['s'], _creds.salt);
      expect(q['v'], SubsonicEndpoints.apiVersion);
      expect(q['c'], 'Linthra');
      expect(q['f'], 'json');
      expect(uri.path, isNot(contains(_creds.token)));
      expect(uri.path, isNot(contains(_creds.salt)));
    });

    test('getLyricsBySongId targets its endpoint and carries the song id', () {
      final Uri uri = SubsonicEndpoints.getLyricsBySongId(
        _base,
        username: _user,
        credentials: _creds,
        songId: 's-7',
      );
      expect(uri.path, '/rest/getLyricsBySongId.view');
      expect(uri.queryParameters['id'], 's-7');
    });

    test('getLyrics targets its endpoint and carries the artist and title', () {
      final Uri uri = SubsonicEndpoints.getLyrics(
        _base,
        username: _user,
        credentials: _creds,
        artist: 'Boards of Canada',
        title: 'Roygbiv',
      );
      expect(uri.path, '/rest/getLyrics.view');
      expect(uri.queryParameters['artist'], 'Boards of Canada');
      expect(uri.queryParameters['title'], 'Roygbiv');
    });

    test('preserves a reverse-proxy subpath, then appends /rest', () {
      // A server mounted under a subpath keeps it ahead of the API path.
      final Uri uri = SubsonicEndpoints.ping(
        'https://example.com/navidrome',
        username: _user,
        credentials: _creds,
      );
      expect(uri.path, '/navidrome/rest/ping.view');
    });
  });

  group('SubsonicEndpoints weaves the standard auth + format query', () {
    final Uri uri =
        SubsonicEndpoints.ping(_base, username: _user, credentials: _creds);

    test('sends u/t/s/v/c/f for token+salt auth', () {
      final Map<String, String> q = uri.queryParameters;
      expect(q['u'], _user);
      expect(q['t'], _creds.token);
      expect(q['s'], _creds.salt);
      expect(q['v'], SubsonicEndpoints.apiVersion);
      expect(q['c'], 'Linthra');
      expect(q['f'], 'json');
    });

    test('the token/salt ride in the query only, never in the path', () {
      // The path the catalog/logs see must never carry the credential.
      expect(uri.path, isNot(contains(_creds.token)));
      expect(uri.path, isNot(contains(_creds.salt)));
      expect(uri.queryParameters['t'], _creds.token);
      expect(uri.queryParameters['s'], _creds.salt);
    });
  });
}
