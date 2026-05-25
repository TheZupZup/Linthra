import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/sources/subsonic/http_subsonic_client.dart';
import 'package:linthra/core/sources/subsonic/subsonic_auth.dart';
import 'package:linthra/core/sources/subsonic/subsonic_exception.dart';

const String _base = 'https://music.example.com';
const _session = SubsonicSession(
  baseUrl: _base,
  username: 'alice',
  salt: 'salt1',
  token: 'tok1',
);
const _credentials = SubsonicCredentials(salt: 'salt1', token: 'tok1');

HttpSubsonicClient _client(MockClient mock) =>
    HttpSubsonicClient(httpClient: mock);

http.Response _ok(Map<String, dynamic> data) => http.Response(
      jsonEncode(<String, dynamic>{
        'subsonic-response': <String, dynamic>{'status': 'ok', ...data},
      }),
      200,
      headers: const <String, String>{'content-type': 'application/json'},
    );

http.Response _failed(int code, String message) => http.Response(
      jsonEncode(<String, dynamic>{
        'subsonic-response': <String, dynamic>{
          'status': 'failed',
          'error': <String, dynamic>{'code': code, 'message': message},
        },
      }),
      200,
      headers: const <String, String>{'content-type': 'application/json'},
    );

void main() {
  group('ping', () {
    test('parses server info and sends the auth + format query', () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return _ok(<String, dynamic>{
          'version': '1.16.1',
          'type': 'navidrome',
          'serverVersion': '0.52.0',
        });
      }));

      final info = await client.ping(
        _base,
        username: 'alice',
        credentials: _credentials,
      );

      expect(info.apiVersion, '1.16.1');
      expect(info.type, 'navidrome');
      expect(info.serverVersion, '0.52.0');
      expect(info.displayProduct, 'Navidrome');

      expect(captured!.url.path, '/rest/ping.view');
      final q = captured!.url.queryParameters;
      expect(q['u'], 'alice');
      expect(q['t'], 'tok1');
      expect(q['s'], 'salt1');
      expect(q['v'], '1.16.1');
      expect(q['c'], 'Linthra');
      expect(q['f'], 'json');
    });

    test('maps Subsonic error 40 to unauthorized', () async {
      final client = _client(
        MockClient((_) async => _failed(40, 'Wrong username or password')),
      );
      expect(
        () => client.ping(_base, username: 'a', credentials: _credentials),
        throwsA(isA<SubsonicException>()
            .having((e) => e.kind, 'kind', SubsonicErrorKind.unauthorized)),
      );
    });

    test('maps Subsonic error 70 to streamUnavailable', () async {
      final client = _client(MockClient((_) async => _failed(70, 'Not found')));
      expect(
        () => client.ping(_base, username: 'a', credentials: _credentials),
        throwsA(isA<SubsonicException>().having(
            (e) => e.kind, 'kind', SubsonicErrorKind.streamUnavailable)),
      );
    });

    test('treats an HTML/non-Subsonic body as notSubsonic', () async {
      final client = _client(
        MockClient((_) async => http.Response('<html>nope</html>', 200)),
      );
      expect(
        () => client.ping(_base, username: 'a', credentials: _credentials),
        throwsA(isA<SubsonicException>()
            .having((e) => e.kind, 'kind', SubsonicErrorKind.notSubsonic)),
      );
    });

    test('maps a transport failure to notReachable', () async {
      final client = _client(
        MockClient((_) async => throw http.ClientException('refused')),
      );
      expect(
        () => client.ping(_base, username: 'a', credentials: _credentials),
        throwsA(isA<SubsonicException>()
            .having((e) => e.kind, 'kind', SubsonicErrorKind.notReachable)),
      );
    });
  });

  group('library listing', () {
    test('getArtists flattens the index → artist lists', () async {
      final client = _client(MockClient((_) async {
        return _ok(<String, dynamic>{
          'artists': <String, dynamic>{
            'index': <Map<String, dynamic>>[
              <String, dynamic>{
                'name': 'K',
                'artist': <Map<String, dynamic>>[
                  <String, dynamic>{'id': 'ar-1', 'name': 'Kavinsky'},
                ],
              },
              <String, dynamic>{
                'name': 'M',
                'artist': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'ar-2',
                    'name': 'M83',
                    'albumCount': 5
                  },
                ],
              },
            ],
          },
        });
      }));

      final artists = await client.getArtists(_session);

      expect(artists.map((a) => a.id), <String>['ar-1', 'ar-2']);
      expect(artists.last.albumCount, 5);
    });

    test('getAlbums parses albumList2 and requests the right type', () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return _ok(<String, dynamic>{
          'albumList2': <String, dynamic>{
            'album': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'al-1',
                'name': 'Drive',
                'artist': 'Kavinsky',
                'songCount': 12,
                'year': 2011,
              },
            ],
          },
        });
      }));

      final albums = await client.getAlbums(_session);

      expect(albums.single.id, 'al-1');
      expect(albums.single.songCount, 12);
      expect(captured!.url.path, '/rest/getAlbumList2.view');
      expect(captured!.url.queryParameters['type'], 'alphabeticalByName');
    });

    test('getAlbumSongs parses the album child list', () async {
      final client = _client(MockClient((_) async {
        return _ok(<String, dynamic>{
          'album': <String, dynamic>{
            'song': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 's1',
                'title': 'Nightcall',
                'artist': 'Kavinsky',
                'duration': 256,
                'track': 1,
              },
            ],
          },
        });
      }));

      final songs = await client.getAlbumSongs(_session, 'al-1');

      expect(songs.single.id, 's1');
      expect(songs.single.durationSeconds, 256);
    });
  });

  group('probeStream', () {
    test('returns the observed status and content type', () async {
      final client = _client(MockClient((_) async => http.Response(
            'data',
            206,
            headers: const <String, String>{'content-type': 'audio/mpeg'},
          )));

      final probe = await client.probeStream(Uri.parse('$_base/rest/stream'));

      expect(probe.statusCode, 206);
      expect(probe.isAudio, isTrue);
    });
  });
}
