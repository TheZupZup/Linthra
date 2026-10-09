import 'dart:async';
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

    test('an error code sent as a string still maps to its kind', () async {
      final client = _client(MockClient((_) async => http.Response(
            jsonEncode(<String, dynamic>{
              'subsonic-response': <String, dynamic>{
                'status': 'failed',
                'error': <String, dynamic>{
                  'code': '40',
                  'message': 'Wrong username or password',
                },
              },
            }),
            200,
          )));
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

    test('getAlbums walks every getAlbumList2 page by offset', () async {
      final List<int> offsets = <int>[];
      // 1,234 albums: two full pages of 500, then a short last page.
      final client = _client(MockClient((http.Request request) async {
        final int size = int.parse(request.url.queryParameters['size']!);
        final int offset = int.parse(request.url.queryParameters['offset']!);
        offsets.add(offset);
        final int end = (offset + size).clamp(0, 1234);
        return _ok(<String, dynamic>{
          'albumList2': <String, dynamic>{
            'album': <Map<String, dynamic>>[
              for (int i = offset; i < end; i++)
                <String, dynamic>{'id': 'al-$i', 'name': 'Album $i'},
            ],
          },
        });
      }));

      final albums = await client.getAlbums(_session);

      expect(offsets, <int>[0, 500, 1000]);
      expect(albums, hasLength(1234));
      expect(albums.first.id, 'al-0');
      expect(albums.last.id, 'al-1233');
    });

    test('a malformed album entry does not end the paging early', () async {
      // A full first page with one unusable entry must still be read as a
      // full page, or everything after it would be silently dropped.
      final List<int> offsets = <int>[];
      final client = _client(MockClient((http.Request request) async {
        final int offset = int.parse(request.url.queryParameters['offset']!);
        offsets.add(offset);
        return _ok(<String, dynamic>{
          'albumList2': <String, dynamic>{
            'album': <Map<String, dynamic>>[
              if (offset == 0) ...<Map<String, dynamic>>[
                <String, dynamic>{'name': 'No id'},
                for (int i = 1; i < 500; i++)
                  <String, dynamic>{'id': 'al-$i', 'name': 'Album $i'},
              ] else
                <String, dynamic>{'id': 'al-last', 'name': 'Last'},
            ],
          },
        });
      }));

      final page =
          await client.getAlbumListPage(_session, size: 500, offset: 0);
      expect(page.entryCount, 500);
      expect(page.albums, hasLength(499));

      offsets.clear();
      final albums = await client.getAlbums(_session);
      expect(offsets, <int>[0, 500]);
      expect(albums.last.id, 'al-last');
    });

    test('HTTP 429 (rate limited) is a retryable server error', () async {
      final client = _client(
        MockClient((_) async => http.Response('Too Many Requests', 429)),
      );

      await expectLater(
        client.getAlbumListPage(_session, size: 500, offset: 0),
        throwsA(isA<SubsonicException>()
            .having((e) => e.kind, 'kind', SubsonicErrorKind.serverError)
            .having((e) => e.statusCode, 'statusCode', 429)),
      );
    });

    test('getAlbumListPage sends size and offset', () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return _ok(<String, dynamic>{
          'albumList2': <String, dynamic>{'album': <Map<String, dynamic>>[]},
        });
      }));

      final page =
          await client.getAlbumListPage(_session, size: 500, offset: 1500);

      expect(page.entryCount, 0);
      expect(page.albums, isEmpty);
      expect(captured!.url.path, '/rest/getAlbumList2.view');
      expect(captured!.url.queryParameters['size'], '500');
      expect(captured!.url.queryParameters['offset'], '1500');
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
    // A Subsonic transcode (and a proxy that drops Range) answers with the
    // whole track. The probe only needs the status line and the headers;
    // reading on would download the track before the engine downloads it
    // again, and on a slow link time out as an unreachable server.
    test('reads the headers only, even when Range is ignored', () async {
      final StreamController<List<int>> body = StreamController<List<int>>();
      bool released = false;
      body.onCancel = () => released = true;
      final client = _client(MockClient.streaming(
        (http.BaseRequest request, http.ByteStream _) async {
          body.add(List<int>.filled(1024, 0));
          return http.StreamedResponse(
            body.stream,
            200,
            headers: const <String, String>{'content-type': 'audio/mpeg'},
          );
        },
      ));

      final probe = await client.probeStream(Uri.parse('$_base/rest/stream'));

      expect(probe.statusCode, 200);
      expect(probe.contentType, 'audio/mpeg');
      // The rest of the body is let go of, not read to the end.
      expect(released, isTrue);
    });

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

    test('a start too large to be finite leaves that line untimed', () async {
      // jsonDecode reads 1e400 as infinity, which toInt throws on. Written out
      // by hand: jsonEncode refuses to produce it.
      final client = _client(MockClient((_) async => http.Response(
            '{"subsonic-response": {"status": "ok", "lyricsList": '
            '{"structuredLyrics": [{"line": ['
            '{"start": 0, "value": "First line"}, '
            '{"start": 1e400, "value": "Second line"}]}]}}}',
            200,
          )));

      final lyrics = await client.fetchLyrics(_session, 's1');

      expect(lyrics!.lines.first.start, Duration.zero);
      expect(lyrics.lines.last.text, 'Second line');
      expect(lyrics.lines.last.start, isNull);
    });

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

    test('parses synced LRC from legacy getLyrics fallback', () async {
      final client = _client(MockClient((http.Request request) async {
        if (request.url.path.endsWith('getLyricsBySongId.view')) {
          return _ok(<String, dynamic>{'lyricsList': <String, dynamic>{}});
        }
        return _ok(<String, dynamic>{
          'lyrics': <String, dynamic>{
            'value': '[00:12.34]First line\n[00:25.50]Second line',
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
      expect(lyrics!.lines, hasLength(2));
      expect(
        lyrics.lines.map((l) => l.text),
        <String>['First line', 'Second line'],
      );
      expect(lyrics.lines.first.start, const Duration(milliseconds: 12340));
      expect(lyrics.lines.last.start, const Duration(milliseconds: 25500));
      expect(lyrics.isSynced, isTrue);
    });

    test('parses plain lyrics from legacy getLyrics fallback', () async {
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
            "value": "  Line one  \r\n\r\nLine two",
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
      expect(
        lyrics.lines.map((l) => l.text),
        <String>["  Line one  ", "", "Line two"],
      );
      expect(lyrics.lines.every((l) => l.start == null), isTrue);
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

  group('scrobble', () {
    test('targets /rest/scrobble.view with the id, flag, and auth query',
        () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return _ok(const <String, dynamic>{});
      }));

      await client.scrobble(_session, 's-7', submission: false);

      expect(captured!.url.path, '/rest/scrobble.view');
      final q = captured!.url.queryParameters;
      expect(q['id'], 's-7');
      expect(q['submission'], 'false');
      expect(q['u'], 'alice');
      expect(q['t'], 'tok1');
      expect(q['s'], 'salt1');
    });

    test('a submission sends submission=true', () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return _ok(const <String, dynamic>{});
      }));

      await client.scrobble(_session, 's-7', submission: true);

      expect(captured!.url.queryParameters['submission'], 'true');
    });

    test('an error envelope throws the typed kind (e.g. an old server)',
        () async {
      // A server that rejects/doesn't support scrobbling answers inside a 200;
      // the typed exception is what the playback reporter swallows.
      final client = _client(
        MockClient((_) async => _failed(30, 'Incompatible version')),
      );

      await expectLater(
        () => client.scrobble(_session, 's-7', submission: true),
        throwsA(isA<SubsonicException>().having(
            (e) => e.kind, 'kind', SubsonicErrorKind.unsupportedResponse)),
      );
    });

    test('a transport failure throws notReachable, never the URL credential',
        () async {
      final client = _client(MockClient((_) async => throw http.ClientException(
            'Connection failed: $_base/rest/scrobble.view?t=tok1&s=salt1',
          )));

      await expectLater(
        () => client.scrobble(_session, 's-7', submission: false),
        throwsA(isA<SubsonicException>()
            .having((e) => e.kind, 'kind', SubsonicErrorKind.notReachable)
            .having((e) => e.message, 'message', isNot(contains('tok1')))
            .having((e) => e.message, 'message', isNot(contains('salt1')))),
      );
    });
  });

  group('favorites (star / unstar / getStarred2)', () {
    test('getStarredSongIds reads the starred2.song list', () async {
      final client = _client(MockClient((_) async {
        return _ok(<String, dynamic>{
          'starred2': <String, dynamic>{
            'song': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'mf-1', 'title': 'One'},
              <String, dynamic>{'id': 'mf-2', 'title': 'Two'},
              // A malformed entry (no id) is skipped, not crashed.
              <String, dynamic>{'title': 'No id'},
            ],
          },
        });
      }));

      final ids = await client.getStarredSongIds(_session);
      expect(ids, <String>{'mf-1', 'mf-2'});
    });

    test('getStarredSongIds returns empty when nothing is starred', () async {
      final client = _client(MockClient((_) async => _ok(<String, dynamic>{})));
      expect(await client.getStarredSongIds(_session), isEmpty);
    });

    test('star sends id to /rest/star.view', () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return _ok(<String, dynamic>{});
      }));

      await client.star(_session, 'mf-9');
      expect(captured!.url.path, '/rest/star.view');
      expect(captured!.url.queryParameters['id'], 'mf-9');
    });

    test('unstar sends id to /rest/unstar.view', () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return _ok(<String, dynamic>{});
      }));

      await client.unstar(_session, 'mf-9');
      expect(captured!.url.path, '/rest/unstar.view');
      expect(captured!.url.queryParameters['id'], 'mf-9');
    });

    test('a star failure surfaces as a typed, credential-free error', () async {
      final client = _client(MockClient((_) async => throw http.ClientException(
            'Connection failed: $_base/rest/star.view?t=tok1&s=salt1',
          )));
      await expectLater(
        () => client.star(_session, 'mf-1'),
        throwsA(isA<SubsonicException>()
            .having((e) => e.message, 'message', isNot(contains('tok1')))
            .having((e) => e.message, 'message', isNot(contains('salt1')))),
      );
    });
  });

  group('playlists', () {
    test('getPlaylists reads the playlists.playlist list', () async {
      final client = _client(MockClient((_) async {
        return _ok(<String, dynamic>{
          'playlists': <String, dynamic>{
            'playlist': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'p-1', 'name': 'Road Trip'},
              <String, dynamic>{'id': 'p-2', 'name': 'Chill'},
            ],
          },
        });
      }));

      final playlists = await client.getPlaylists(_session);
      expect(playlists.map((p) => p.id), <String>['p-1', 'p-2']);
      expect(playlists.map((p) => p.name), <String>['Road Trip', 'Chill']);
    });

    test('getPlaylistSongIds reads the entry list in order', () async {
      final client = _client(MockClient((http.Request request) async {
        expect(request.url.path, '/rest/getPlaylist.view');
        expect(request.url.queryParameters['id'], 'p-1');
        return _ok(<String, dynamic>{
          'playlist': <String, dynamic>{
            'id': 'p-1',
            'entry': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'mf-3', 'title': 'C'},
              <String, dynamic>{'id': 'mf-1', 'title': 'A'},
              <String, dynamic>{'id': 'mf-2', 'title': 'B'},
            ],
          },
        });
      }));

      final ids = await client.getPlaylistSongIds(_session, 'p-1');
      expect(ids, <String>['mf-3', 'mf-1', 'mf-2']);
    });

    test('createPlaylist sends name + songId list and returns the new id',
        () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return _ok(<String, dynamic>{
          'playlist': <String, dynamic>{'id': 'p-new', 'name': 'Fresh'},
        });
      }));

      final id = await client.createPlaylist(
        _session,
        name: 'Fresh',
        songIds: <String>['mf-1', 'mf-2'],
      );
      expect(id, 'p-new');
      expect(captured!.url.path, '/rest/createPlaylist.view');
      expect(captured!.url.queryParameters['name'], 'Fresh');
      // The repeated songId key preserves order.
      expect(
          captured!.url.queryParametersAll['songId'], <String>['mf-1', 'mf-2']);
    });

    test('createPlaylist falls back to matching by name if none is returned',
        () async {
      int calls = 0;
      final client = _client(MockClient((http.Request request) async {
        calls++;
        if (request.url.path == '/rest/createPlaylist.view') {
          // A server that returns an empty ok (no playlist object).
          return _ok(<String, dynamic>{});
        }
        // getPlaylists fallback.
        return _ok(<String, dynamic>{
          'playlists': <String, dynamic>{
            'playlist': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'p-old', 'name': 'Other'},
              <String, dynamic>{'id': 'p-fresh', 'name': 'Fresh'},
            ],
          },
        });
      }));

      final id = await client.createPlaylist(_session, name: 'Fresh');
      expect(id, 'p-fresh');
      expect(calls, 2);
    });

    test('setPlaylistSongs replaces via createPlaylist with playlistId',
        () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return _ok(<String, dynamic>{});
      }));

      await client
          .setPlaylistSongs(_session, 'p-1', <String>['mf-2', 'mf-1', 'mf-3']);
      expect(captured!.url.path, '/rest/createPlaylist.view');
      expect(captured!.url.queryParameters['playlistId'], 'p-1');
      expect(captured!.url.queryParametersAll['songId'],
          <String>['mf-2', 'mf-1', 'mf-3']);
    });

    test('renamePlaylist updates the name via updatePlaylist', () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return _ok(<String, dynamic>{});
      }));

      await client.renamePlaylist(_session, 'p-1', 'Renamed');
      expect(captured!.url.path, '/rest/updatePlaylist.view');
      expect(captured!.url.queryParameters['playlistId'], 'p-1');
      expect(captured!.url.queryParameters['name'], 'Renamed');
    });

    test('deletePlaylist sends id to /rest/deletePlaylist.view', () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return _ok(<String, dynamic>{});
      }));

      await client.deletePlaylist(_session, 'p-1');
      expect(captured!.url.path, '/rest/deletePlaylist.view');
      expect(captured!.url.queryParameters['id'], 'p-1');
    });

    test('a playlist write failure maps to a friendly, credential-free error',
        () async {
      final client = _client(MockClient((_) async => throw http.ClientException(
            'Connection failed: $_base/rest/createPlaylist.view?t=tok1&s=salt1',
          )));
      await expectLater(
        () => client.setPlaylistSongs(_session, 'p-1', <String>['mf-1']),
        throwsA(isA<SubsonicException>()
            .having((e) => e.message, 'message', isNot(contains('tok1')))
            .having((e) => e.message, 'message', isNot(contains('salt1')))),
      );
    });
  });

  group('large playlist writes (#796)', () {
    // Navidrome-style ids: about 30 to 40 bytes per song in the URL, so 400
    // songs is well past the 8 KB nginx and Apache allow by default.
    List<String> manySongs(int count) => <String>[
          for (int i = 0; i < count; i++)
            'b3f6a1c2d4e5f60718293a4b5c6d7e${i.toString().padLeft(4, '0')}',
        ];

    http.Response extensions(List<String> names) => _ok(<String, dynamic>{
          'openSubsonic': true,
          'openSubsonicExtensions': <Map<String, dynamic>>[
            for (final String name in names)
              <String, dynamic>{
                'name': name,
                'versions': <int>[1],
              },
          ],
        });

    test('a small edit stays one GET, without asking about extensions',
        () async {
      final List<http.Request> requests = <http.Request>[];
      final client = _client(MockClient((http.Request request) async {
        requests.add(request);
        return _ok(<String, dynamic>{});
      }));

      await client.setPlaylistSongs(_session, 'p-1', manySongs(3));

      expect(requests, hasLength(1));
      expect(requests.single.method, 'GET');
      expect(requests.single.url.path, '/rest/createPlaylist.view');
    });

    test('a big playlist goes as a form POST when the server lists formPost',
        () async {
      final List<http.Request> requests = <http.Request>[];
      final client = _client(MockClient((http.Request request) async {
        requests.add(request);
        if (request.url.path == '/rest/getOpenSubsonicExtensions.view') {
          return extensions(<String>['songLyrics', 'formPost']);
        }
        return _ok(<String, dynamic>{});
      }));
      // Duplicates are allowed in a Subsonic playlist and must survive.
      final List<String> songs = <String>[
        ...manySongs(400),
        'b3f6a1c2d4e5f60718293a4b5c6d7e0007',
      ];

      await client.setPlaylistSongs(_session, 'p-1', songs);

      expect(requests, hasLength(2));
      final http.Request write = requests.last;
      expect(write.method, 'POST');
      expect(write.url.toString(), '$_base/rest/createPlaylist.view');
      expect(write.headers['Content-Type'],
          startsWith('application/x-www-form-urlencoded'));
      // Nothing secret, nothing at all, in the URL a proxy would log.
      expect(write.url.query, isEmpty);
      final Map<String, List<String>> form =
          Uri(query: write.body).queryParametersAll;
      expect(form['playlistId'], <String>['p-1']);
      expect(form['songId'], songs);
      expect(form['u'], <String>['alice']);
      expect(form['t'], <String>['tok1']);
      expect(form['s'], <String>['salt1']);
      expect(form['f'], <String>['json']);
    });

    test('form values are encoded the way a form expects', () async {
      http.Request? write;
      final client = _client(MockClient((http.Request request) async {
        if (request.url.path == '/rest/getOpenSubsonicExtensions.view') {
          return extensions(<String>['formPost']);
        }
        write = request;
        return _ok(<String, dynamic>{});
      }));
      final List<String> songs = <String>[
        'a b+c&d=e',
        'caf\u00e9/%',
        ...manySongs(400),
      ];

      await client.setPlaylistSongs(_session, 'p 1', songs);

      // Read back the way a form parser reads it (`+` is a space there).
      final Map<String, List<String>> form =
          Uri(query: write!.body).queryParametersAll;
      expect(form['playlistId'], <String>['p 1']);
      expect(form['songId'], songs);
    });

    test('a new big playlist goes as a form POST too', () async {
      final List<http.Request> requests = <http.Request>[];
      final client = _client(MockClient((http.Request request) async {
        requests.add(request);
        if (request.url.path == '/rest/getOpenSubsonicExtensions.view') {
          return extensions(<String>['formPost']);
        }
        return _ok(<String, dynamic>{
          'playlist': <String, dynamic>{'id': 'p-new'},
        });
      }));

      final String id = await client.createPlaylist(
        _session,
        name: 'Everything',
        songIds: manySongs(400),
      );

      expect(id, 'p-new');
      expect(requests.last.method, 'POST');
      expect(
          Uri(query: requests.last.body).queryParameters['name'], 'Everything');
    });

    test('formPost is asked about once per server', () async {
      int lookups = 0;
      final client = _client(MockClient((http.Request request) async {
        if (request.url.path == '/rest/getOpenSubsonicExtensions.view') {
          lookups++;
          return extensions(<String>['formPost']);
        }
        return _ok(<String, dynamic>{});
      }));

      await Future.wait(<Future<void>>[
        client.setPlaylistSongs(_session, 'p-1', manySongs(400)),
        client.setPlaylistSongs(_session, 'p-2', manySongs(401)),
      ]);
      await client.setPlaylistSongs(_session, 'p-3', manySongs(402));

      expect(lookups, 1);
    });

    test(
        'without formPost a big playlist still goes as a GET, which a server '
        'with no proxy in front takes', () async {
      final List<http.Request> requests = <http.Request>[];
      final client = _client(MockClient((http.Request request) async {
        requests.add(request);
        if (request.url.path == '/rest/getOpenSubsonicExtensions.view') {
          return extensions(<String>['songLyrics']);
        }
        return _ok(<String, dynamic>{});
      }));

      await client.setPlaylistSongs(_session, 'p-1', manySongs(400));

      expect(requests.last.method, 'GET');
      expect(requests.last.url.queryParametersAll['songId'], manySongs(400));
    });

    test('a server without OpenSubsonic is not asked to take a form', () async {
      final List<http.Request> requests = <http.Request>[];
      final client = _client(MockClient((http.Request request) async {
        requests.add(request);
        if (request.url.path == '/rest/getOpenSubsonicExtensions.view') {
          return http.Response('Not Found', 404);
        }
        return _ok(<String, dynamic>{});
      }));

      await client.setPlaylistSongs(_session, 'p-1', manySongs(400));

      expect(requests.last.method, 'GET');
    });

    for (final int status in <int>[414, 431]) {
      test('a proxy turning the URL down ($status) says so, without secrets',
          () async {
        final client = _client(MockClient((http.Request request) async {
          if (request.url.path == '/rest/getOpenSubsonicExtensions.view') {
            return _failed(0, 'Unknown method');
          }
          return http.Response('<html>Request-URI Too Large</html>', status);
        }));

        Object? caught;
        try {
          await client.setPlaylistSongs(_session, 'p-1', manySongs(400));
        } catch (error) {
          caught = error;
        }

        expect(
          caught,
          isA<SubsonicException>()
              .having((SubsonicException e) => e.statusCode, 'status', status)
              .having((SubsonicException e) => e.kind, 'kind',
                  isNot(SubsonicErrorKind.notSubsonic))
              .having((SubsonicException e) => e.message, 'message',
                  contains('too many songs')),
        );
        expect('$caught', isNot(contains('tok1')));
        expect('$caught', isNot(contains('salt1')));
      });
    }

    test('a 414 on an ordinary request is unchanged', () async {
      final client = _client(MockClient((_) async {
        return http.Response('', 414);
      }));

      await expectLater(
        client.verifySession(_session),
        throwsA(isA<SubsonicException>().having((SubsonicException e) => e.kind,
            'kind', SubsonicErrorKind.notSubsonic)),
      );
    });

    test(
        'a lookup that cannot reach the server fails the write and is asked '
        'again next time', () async {
      bool offline = true;
      int lookups = 0;
      final List<http.Request> writes = <http.Request>[];
      final client = _client(MockClient((http.Request request) async {
        if (request.url.path == '/rest/getOpenSubsonicExtensions.view') {
          lookups++;
          if (offline) {
            throw http.ClientException('Connection failed: ${request.url}');
          }
          return extensions(<String>['formPost']);
        }
        writes.add(request);
        return _ok(<String, dynamic>{});
      }));

      Object? caught;
      try {
        await client.setPlaylistSongs(_session, 'p-1', manySongs(400));
      } catch (error) {
        caught = error;
      }
      expect(
        caught,
        isA<SubsonicException>().having((SubsonicException e) => e.kind, 'kind',
            SubsonicErrorKind.notReachable),
      );
      expect('$caught', isNot(contains('tok1')));
      // Nothing was sent: no half-written playlist on the server.
      expect(writes, isEmpty);

      offline = false;
      await client.setPlaylistSongs(_session, 'p-1', manySongs(400));
      expect(lookups, 2);
      expect(writes.single.method, 'POST');
    });

    test('a refused form POST surfaces like any refused write', () async {
      final client = _client(MockClient((http.Request request) async {
        if (request.url.path == '/rest/getOpenSubsonicExtensions.view') {
          return extensions(<String>['formPost']);
        }
        return _failed(50, 'not authorized');
      }));

      await expectLater(
        client.setPlaylistSongs(_session, 'p-1', manySongs(400)),
        throwsA(isA<SubsonicException>().having((SubsonicException e) => e.kind,
            'kind', SubsonicErrorKind.unauthorized)),
      );
    });
  });
}
