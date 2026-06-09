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

    test('maps a blocked cleartext request to cleartextBlocked', () async {
      final client = _client(MockClient((_) async => throw http.ClientException(
            'Cleartext HTTP traffic to 192.168.1.50 not permitted',
          )));
      expect(
        () => client.ping(_base, username: 'a', credentials: _credentials),
        throwsA(isA<SubsonicException>()
            .having((e) => e.kind, 'kind', SubsonicErrorKind.cleartextBlocked)),
      );
    });

    test('maps a TLS handshake failure to insecureConnection', () async {
      final client = _client(MockClient((_) async => throw http.ClientException(
            'HandshakeException: Handshake error in client '
            '(OS Error: CERTIFICATE_VERIFY_FAILED: self signed certificate)',
          )));
      expect(
        () => client.ping(_base, username: 'a', credentials: _credentials),
        throwsA(isA<SubsonicException>().having(
            (e) => e.kind, 'kind', SubsonicErrorKind.insecureConnection)),
      );
    });

    test('never echoes a credential-bearing error message', () async {
      // A ClientException's text can include the request URL (token+salt). The
      // thrown message must be the static factory text, never the raw error.
      final client = _client(MockClient((_) async => throw http.ClientException(
            'Connection failed: $_base/rest/ping.view?u=a&t=tok1&s=salt1',
          )));
      await expectLater(
        () => client.ping(_base, username: 'a', credentials: _credentials),
        throwsA(isA<SubsonicException>()
            .having((e) => e.message, 'message', isNot(contains('tok1')))
            .having((e) => e.message, 'message', isNot(contains('salt1')))),
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
                  <String, dynamic>{
                    'id': 'ar-1',
                    'name': 'Kavinsky',
                    'coverArt': 'ar-1',
                  },
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
      // The cover-art handle is parsed when present, absent otherwise.
      expect(artists.first.coverArt, 'ar-1');
      expect(artists.last.coverArt, isNull);
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
                'coverArt': 'al-1',
              },
            ],
          },
        });
      }));

      final albums = await client.getAlbums(_session);

      expect(albums.single.id, 'al-1');
      expect(albums.single.songCount, 12);
      expect(albums.single.coverArt, 'al-1');
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
                'coverArt': 'al-1',
              },
            ],
          },
        });
      }));

      final songs = await client.getAlbumSongs(_session, 'al-1');

      expect(songs.single.id, 's1');
      expect(songs.single.durationSeconds, 256);
      expect(songs.single.coverArt, 'al-1');
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

  group('fetchLyrics', () {
    // Builds a getLyricsBySongId envelope from one structured-lyrics set.
    http.Response structured(Map<String, dynamic> set) {
      return _ok(<String, dynamic>{
        'lyricsList': <String, dynamic>{
          'structuredLyrics': <Map<String, dynamic>>[set],
        },
      });
    }

    test('parses synced structuredLyrics with millisecond starts', () async {
      final client = _client(MockClient((_) async {
        return structured(<String, dynamic>{
          'displayArtist': 'Kavinsky',
          'displayTitle': 'Nightcall',
          'lang': 'eng',
          'offset': 0,
          'synced': true,
          'line': <Map<String, dynamic>>[
            <String, dynamic>{'start': 0, 'value': 'First line'},
            <String, dynamic>{'start': 1500, 'value': 'Second line'},
          ],
        });
      }));

      final lyrics = await client.fetchLyrics(_session, 's1');

      expect(lyrics, isNotNull);
      expect(lyrics!.isSynced, isTrue);
      expect(
        lyrics.lines.map((l) => l.text),
        <String>['First line', 'Second line'],
      );
      expect(lyrics.lines.first.start, Duration.zero);
      expect(lyrics.lines.last.start, const Duration(milliseconds: 1500));
    });

    test('applies the entry offset to every synced start', () async {
      final client = _client(MockClient((_) async {
        return structured(<String, dynamic>{
          'synced': true,
          'offset': 250,
          'line': <Map<String, dynamic>>[
            <String, dynamic>{'start': 1000, 'value': 'x'},
          ],
        });
      }));

      final lyrics = await client.fetchLyrics(_session, 's1');

      expect(lyrics!.lines.single.start, const Duration(milliseconds: 1250));
    });

    test('parses plain structuredLyrics (no timestamps) as untimed', () async {
      final client = _client(MockClient((_) async {
        return structured(<String, dynamic>{
          'line': <Map<String, dynamic>>[
            <String, dynamic>{'value': 'la la'},
            <String, dynamic>{'value': 'la la la'},
          ],
        });
      }));

      final lyrics = await client.fetchLyrics(_session, 's1');

      expect(lyrics, isNotNull);
      expect(lyrics!.isSynced, isFalse);
      expect(lyrics.lines.every((l) => l.start == null), isTrue);
      expect(lyrics.lines.map((l) => l.text), <String>['la la', 'la la la']);
    });

    test('treats a set flagged synced:false as plain even with starts',
        () async {
      final client = _client(MockClient((_) async {
        return structured(<String, dynamic>{
          'synced': false,
          'line': <Map<String, dynamic>>[
            <String, dynamic>{'start': 0, 'value': 'a'},
            <String, dynamic>{'start': 0, 'value': 'b'},
          ],
        });
      }));

      final lyrics = await client.fetchLyrics(_session, 's1');

      expect(lyrics!.isSynced, isFalse);
      expect(lyrics.lines.every((l) => l.start == null), isTrue);
    });

    test('uses the first structured set when several languages are present',
        () async {
      final client = _client(MockClient((_) async {
        return _ok(<String, dynamic>{
          'lyricsList': <String, dynamic>{
            'structuredLyrics': <Map<String, dynamic>>[
              <String, dynamic>{
                'lang': 'eng',
                'line': <Map<String, dynamic>>[
                  <String, dynamic>{'value': 'english'},
                ],
              },
              <String, dynamic>{
                'lang': 'fra',
                'line': <Map<String, dynamic>>[
                  <String, dynamic>{'value': 'french'},
                ],
              },
            ],
          },
        });
      }));

      final lyrics = await client.fetchLyrics(_session, 's1');

      expect(lyrics!.lines.single.text, 'english');
    });

    test('sends the song id and does not fall back when lyrics are found',
        () async {
      final List<String> paths = <String>[];
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        paths.add(request.url.path);
        captured = request;
        return structured(<String, dynamic>{
          'line': <Map<String, dynamic>>[
            <String, dynamic>{'value': 'found'},
          ],
        });
      }));

      final lyrics = await client.fetchLyrics(
        _session,
        's-42',
        artist: 'Kavinsky',
        title: 'Nightcall',
      );

      expect(lyrics!.lines.single.text, 'found');
      // Only the primary endpoint was hit — the legacy fallback is skipped.
      expect(paths, <String>['/rest/getLyricsBySongId.view']);
      expect(captured!.url.queryParameters['id'], 's-42');
    });

    test('falls back to legacy getLyrics when the primary has none', () async {
      http.Request? legacy;
      final client = _client(MockClient((http.Request request) async {
        if (request.url.path.endsWith('getLyricsBySongId.view')) {
          // Server supports the call but has no lyrics for this song.
          return _ok(<String, dynamic>{'lyricsList': <String, dynamic>{}});
        }
        legacy = request;
        return _ok(<String, dynamic>{
          'lyrics': <String, dynamic>{
            'artist': 'Kavinsky',
            'title': 'Nightcall',
            'value': 'Line one\r\nLine two',
          },
        });
      }));

      final lyrics = await client.fetchLyrics(
        _session,
        's1',
        artist: 'Kavinsky',
        title: 'Nightcall',
      );

      expect(lyrics, isNotNull);
      expect(lyrics!.isSynced, isFalse);
      expect(lyrics.lines.map((l) => l.text), <String>['Line one', 'Line two']);
      expect(legacy!.url.queryParameters['artist'], 'Kavinsky');
      expect(legacy!.url.queryParameters['title'], 'Nightcall');
    });

    test('returns null when neither endpoint has lyrics', () async {
      final client = _client(MockClient((http.Request request) async {
        if (request.url.path.endsWith('getLyricsBySongId.view')) {
          return _ok(<String, dynamic>{'lyricsList': <String, dynamic>{}});
        }
        return _ok(<String, dynamic>{
          'lyrics': <String, dynamic>{'value': ''},
        });
      }));

      final lyrics = await client.fetchLyrics(
        _session,
        's1',
        artist: 'A',
        title: 'T',
      );

      expect(lyrics, isNull);
    });

    test('a failed/unsupported primary response yields null, never throws',
        () async {
      // A server without the extension answers with a Subsonic error envelope;
      // with no artist/title to fall back on, that's a calm "no lyrics", not an
      // error.
      final client = _client(
        MockClient((_) async => _failed(0, 'Wrong arguments')),
      );

      final lyrics = await client.fetchLyrics(_session, 's1');

      expect(lyrics, isNull);
    });

    test('a transport failure throws notReachable', () async {
      final client = _client(
        MockClient((_) async => throw http.ClientException('refused')),
      );

      await expectLater(
        () => client.fetchLyrics(_session, 's1'),
        throwsA(isA<SubsonicException>()
            .having((e) => e.kind, 'kind', SubsonicErrorKind.notReachable)),
      );
    });

    test('never echoes a credential-bearing error message', () async {
      final client = _client(MockClient((_) async => throw http.ClientException(
            'Connection failed: $_base/rest/getLyricsBySongId.view?t=tok1&s=salt1',
          )));

      await expectLater(
        () => client.fetchLyrics(_session, 's1'),
        throwsA(isA<SubsonicException>()
            .having((e) => e.message, 'message', isNot(contains('tok1')))
            .having((e) => e.message, 'message', isNot(contains('salt1')))),
      );
    });
  });
}
