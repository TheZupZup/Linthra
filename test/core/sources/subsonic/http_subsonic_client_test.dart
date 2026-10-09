import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

    // What a lookup's outcome means for the write (#850 review). Only a
    // real answer is remembered; a lookup that said nothing either way sends
    // the write as a GET, as before form posts, and is asked again.
    bool isLookup(http.Request request) =>
        request.url.path.endsWith('/rest/getOpenSubsonicExtensions.view');

    /// [caught] carries none of the session's secrets, nor the server address.
    void expectNoSecrets(Object? caught) {
      for (final String secret in <String>['tok1', 'salt1', 'music.example']) {
        expect('$caught', isNot(contains(secret)));
        if (caught is SubsonicException) {
          expect(caught.message, isNot(contains(secret)));
        }
      }
    }

    final Map<String, http.Response Function()> noAnswers =
        <String, http.Response Function()>{
      'HTTP 500': () => http.Response('Internal Server Error', 500),
      'HTTP 502': () => http.Response('<html>Bad Gateway</html>', 502),
      'HTTP 503': () => http.Response('Service Unavailable', 503),
      'HTTP 429': () => http.Response('Too Many Requests', 429),
      'Subsonic error 0': () => _failed(0, 'A generic error'),
      'an HTML page with status 200': () => http.Response(
          '<html>Maintenance</html>', 200,
          headers: const <String, String>{'content-type': 'text/html'}),
    };

    for (final MapEntry<String, http.Response Function()> outcome
        in noAnswers.entries) {
      test(
          'a lookup answered with ${outcome.key} still sends the write, as a '
          'GET, and asks again next time', () async {
        bool answered = false;
        int lookups = 0;
        final List<http.Request> writes = <http.Request>[];
        final client = _client(MockClient((http.Request request) async {
          if (isLookup(request)) {
            lookups++;
            return answered
                ? extensions(<String>['formPost'])
                : outcome.value();
          }
          writes.add(request);
          return _ok(<String, dynamic>{});
        }));
        final List<String> songs = manySongs(400);

        await client.setPlaylistSongs(_session, 'p-1', songs);

        expect(writes.single.method, 'GET');
        expect(writes.single.url.queryParametersAll['songId'], songs);

        // A later lookup that does answer is not shut out by the first.
        answered = true;
        await client.setPlaylistSongs(_session, 'p-1', songs);
        expect(lookups, 2);
        expect(writes.last.method, 'POST');
      });
    }

    test(
        'a lookup server error, then a proxy refusing the long GET, says the '
        'playlist is too long without secrets', () async {
      final client = _client(MockClient((http.Request request) async {
        if (isLookup(request)) return http.Response('', 500);
        return http.Response('<html>414 Request-URI Too Large</html>', 414);
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
            .having((SubsonicException e) => e.statusCode, 'status', 414)
            .having((SubsonicException e) => e.kind, 'kind',
                isNot(SubsonicErrorKind.notSubsonic)),
      );
      expectNoSecrets(caught);
    });

    final Map<String, http.Response Function()> noFormPost =
        <String, http.Response Function()>{
      'no such endpoint (404)': () => http.Response('Not Found', 404),
      'Subsonic error 70 (no such data)': () => _failed(70, 'Not found'),
      'a list without formPost': () => extensions(<String>['songLyrics']),
      'formPost in a version this client does not speak': () => _ok(
            <String, dynamic>{
              'openSubsonicExtensions': <Map<String, dynamic>>[
                <String, dynamic>{
                  'name': 'formPost',
                  'versions': <int>[2],
                },
              ],
            },
          ),
    };

    for (final MapEntry<String, http.Response Function()> answer
        in noFormPost.entries) {
      test('${answer.key} is a real no: kept, and writes go as GETs', () async {
        int lookups = 0;
        final List<http.Request> writes = <http.Request>[];
        final client = _client(MockClient((http.Request request) async {
          if (isLookup(request)) {
            lookups++;
            return answer.value();
          }
          writes.add(request);
          return _ok(<String, dynamic>{});
        }));

        await client.setPlaylistSongs(_session, 'p-1', manySongs(400));
        await client.setPlaylistSongs(_session, 'p-2', manySongs(401));

        expect(lookups, 1);
        expect(
            writes.map((http.Request w) => w.method), <String>['GET', 'GET']);
      });
    }

    test('a yes is kept, even when the lookup would fail later', () async {
      int lookups = 0;
      final List<http.Request> writes = <http.Request>[];
      final client = _client(MockClient((http.Request request) async {
        if (isLookup(request)) {
          lookups++;
          return lookups == 1
              ? extensions(<String>['formPost'])
              : http.Response('', 500);
        }
        writes.add(request);
        return _ok(<String, dynamic>{});
      }));

      await client.setPlaylistSongs(_session, 'p-1', manySongs(400));
      await client.setPlaylistSongs(_session, 'p-2', manySongs(400));

      expect(lookups, 1);
      expect(
          writes.map((http.Request w) => w.method), <String>['POST', 'POST']);
    });

    final Map<String, (Object, SubsonicErrorKind)> refusals =
        <String, (Object, SubsonicErrorKind)>{
      'refused credentials (401)': (
        http.Response('', 401),
        SubsonicErrorKind.unauthorized,
      ),
      'wrong credentials (Subsonic error 40)': (
        _failed(40, 'Wrong username or password'),
        SubsonicErrorKind.unauthorized,
      ),
      'a failed TLS handshake': (
        http.ClientException('HandshakeException: CERTIFICATE_VERIFY_FAILED '
            'https://music.example.com/rest?t=tok1&s=salt1'),
        SubsonicErrorKind.insecureConnection,
      ),
      'an unreachable server': (
        http.ClientException(
            'SocketException https://music.example.com/rest?t=tok1&s=salt1'),
        SubsonicErrorKind.notReachable,
      ),
    };

    for (final MapEntry<String, (Object, SubsonicErrorKind)> refusal
        in refusals.entries) {
      test(
          'a lookup failing on ${refusal.key} sends nothing, says so, and is '
          'asked again next time', () async {
        bool fixed = false;
        int lookups = 0;
        final List<http.Request> writes = <http.Request>[];
        final client = _client(MockClient((http.Request request) async {
          if (isLookup(request)) {
            lookups++;
            if (fixed) return extensions(<String>['formPost']);
            final Object outcome = refusal.value.$1;
            if (outcome is http.Response) return outcome;
            throw outcome;
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

        // Same server, same credentials: the write would fail the same way,
        // and this is the error that says why.
        expect(
          caught,
          isA<SubsonicException>().having(
              (SubsonicException e) => e.kind, 'kind', refusal.value.$2),
        );
        expectNoSecrets(caught);
        expect(writes, isEmpty);

        fixed = true;
        await client.setPlaylistSongs(_session, 'p-1', manySongs(400));
        expect(lookups, 2);
        expect(writes.single.method, 'POST');
      });
    }

    group('writes waiting on one lookup', () {
      late Completer<http.Response> pending;
      late int lookups;
      late List<http.Request> writes;
      late HttpSubsonicClient client;

      setUp(() {
        pending = Completer<http.Response>();
        lookups = 0;
        writes = <http.Request>[];
        client = _client(MockClient((http.Request request) async {
          if (isLookup(request)) {
            lookups++;
            return lookups == 1
                ? pending.future
                : extensions(<String>['formPost']);
          }
          writes.add(request);
          return _ok(<String, dynamic>{});
        }));
      });

      test('share it, and all go as form posts once it says yes', () async {
        final Future<void> first =
            client.setPlaylistSongs(_session, 'p-1', manySongs(400));
        final Future<void> second =
            client.setPlaylistSongs(_session, 'p-2', manySongs(401));
        await pumpEventQueue();
        expect(lookups, 1);
        expect(writes, isEmpty);

        pending.complete(extensions(<String>['formPost']));
        await Future.wait(<Future<void>>[first, second]);

        expect(lookups, 1);
        expect(
            writes.map((http.Request w) => w.method), <String>['POST', 'POST']);
      });

      test('all go as GETs when it says nothing, and the next write asks again',
          () async {
        final Future<void> first =
            client.setPlaylistSongs(_session, 'p-1', manySongs(400));
        final Future<void> second =
            client.setPlaylistSongs(_session, 'p-2', manySongs(401));
        await pumpEventQueue();

        pending.complete(http.Response('', 503));
        await Future.wait(<Future<void>>[first, second]);
        expect(
            writes.map((http.Request w) => w.method), <String>['GET', 'GET']);

        await client.setPlaylistSongs(_session, 'p-3', manySongs(402));
        expect(lookups, 2);
        expect(writes.last.method, 'POST');
      });

      test('none is sent when it cannot reach the server', () async {
        final Future<void> first =
            client.setPlaylistSongs(_session, 'p-1', manySongs(400));
        final Future<void> second =
            client.setPlaylistSongs(_session, 'p-2', manySongs(401));
        await pumpEventQueue();

        pending.completeError(http.ClientException('Connection reset'));
        for (final Future<void> write in <Future<void>>[first, second]) {
          await expectLater(
            write,
            throwsA(isA<SubsonicException>().having(
                (SubsonicException e) => e.kind,
                'kind',
                SubsonicErrorKind.notReachable)),
          );
        }
        expect(writes, isEmpty);
      });
    });

    test(
        "one user's lookup failing on their credentials does not fail "
        "another user's write", () async {
      const SubsonicSession bob = SubsonicSession(
        baseUrl: _base,
        username: 'bob',
        salt: 'salt2',
        token: 'tok2',
      );
      final Completer<http.Response> aliceLookup = Completer<http.Response>();
      final List<http.Request> writes = <http.Request>[];
      final client = _client(MockClient((http.Request request) async {
        final String? user = request.url.queryParameters['u'];
        if (isLookup(request)) {
          return user == 'alice'
              ? aliceLookup.future
              : extensions(<String>['formPost']);
        }
        writes.add(request);
        return _ok(<String, dynamic>{});
      }));

      // Alice's session was signed out on the server meanwhile.
      final Future<void> alice =
          client.setPlaylistSongs(_session, 'p-1', manySongs(400));
      await pumpEventQueue();
      final Future<void> bobs =
          client.setPlaylistSongs(bob, 'p-2', manySongs(400));
      await pumpEventQueue();
      aliceLookup.complete(http.Response('', 401));

      await expectLater(alice, throwsA(isA<SubsonicException>()));
      await bobs;
      expect(writes.single.method, 'POST');
      expect(
        Uri(query: writes.single.body).queryParameters['u'],
        'bob',
      );
    });

    test('two servers keep their own answers', () async {
      const SubsonicSession other = SubsonicSession(
        baseUrl: 'https://other.example.org',
        username: 'alice',
        salt: 'salt1',
        token: 'tok1',
      );
      final List<http.Request> writes = <http.Request>[];
      final client = _client(MockClient((http.Request request) async {
        if (isLookup(request)) {
          return request.url.host == 'music.example.com'
              ? extensions(<String>['formPost'])
              : http.Response('Not Found', 404);
        }
        writes.add(request);
        return _ok(<String, dynamic>{});
      }));

      // The same song ids on both servers.
      await client.setPlaylistSongs(_session, 'p-1', manySongs(400));
      await client.setPlaylistSongs(other, 'p-1', manySongs(400));
      await client.setPlaylistSongs(_session, 'p-1', manySongs(400));

      expect(
        writes.map((http.Request w) => '${w.method} ${w.url.host}'),
        <String>[
          'POST music.example.com',
          'GET other.example.org',
          'POST music.example.com',
        ],
      );
    });

    final Map<String, http.Response Function()> failedWrites =
        <String, http.Response Function()>{
      'HTTP 500': () => http.Response('', 500),
      'HTTP 502 from a proxy': () =>
          http.Response('<html>Bad Gateway</html>', 502),
      'a Subsonic error': () => _failed(10, 'Required parameter is missing'),
      'an HTML page': () => http.Response('<html>Login</html>', 200),
    };

    for (final bool formPost in <bool>[true, false]) {
      for (final MapEntry<String, http.Response Function()> failure
          in failedWrites.entries) {
        test(
            'a ${formPost ? 'form POST' : 'long GET'} write failing with '
            '${failure.key} throws, once, without secrets', () async {
          final List<http.Request> writes = <http.Request>[];
          final client = _client(MockClient((http.Request request) async {
            if (isLookup(request)) {
              return formPost
                  ? extensions(<String>['formPost'])
                  : extensions(<String>[]);
            }
            writes.add(request);
            return failure.value();
          }));

          Object? caught;
          try {
            await client.setPlaylistSongs(_session, 'p-1', manySongs(400));
          } catch (error) {
            caught = error;
          }

          // The server may or may not have applied it; either way this is
          // not a success, and it is not sent again behind the user's back.
          expect(caught, isA<SubsonicException>());
          expectNoSecrets(caught);
          expect(writes, hasLength(1));
          expect(writes.single.method, formPost ? 'POST' : 'GET');
        });
      }
    }

    test(
        'a proxy refusing a form POST as too large (413) says so, without '
        'secrets', () async {
      final client = _client(MockClient((http.Request request) async {
        if (isLookup(request)) return extensions(<String>['formPost']);
        return http.Response('<html>413 Request Entity Too Large</html>', 413);
      }));

      Object? caught;
      try {
        await client.setPlaylistSongs(_session, 'p-1', manySongs(4000));
      } catch (error) {
        caught = error;
      }

      expect(
        caught,
        isA<SubsonicException>()
            .having((SubsonicException e) => e.statusCode, 'status', 413)
            .having((SubsonicException e) => e.kind, 'kind',
                isNot(SubsonicErrorKind.notSubsonic))
            .having((SubsonicException e) => e.message, 'message',
                contains('too large')),
      );
      expectNoSecrets(caught);
    });

    for (final String base in <String>[
      'https://box.example.com:8443/navidrome',
      'http://[fd00::1]:4533',
    ]) {
      test('the form goes to the same endpoint under $base', () async {
        final SubsonicSession session = SubsonicSession(
          baseUrl: base,
          username: 'alice',
          salt: 'salt1',
          token: 'tok1',
        );
        http.Request? write;
        final client = _client(MockClient((http.Request request) async {
          if (isLookup(request)) return extensions(<String>['formPost']);
          write = request;
          return _ok(<String, dynamic>{});
        }));

        await client.setPlaylistSongs(session, 'p-1', manySongs(400));

        expect(write!.method, 'POST');
        expect(write!.url.toString(), '$base/rest/createPlaylist.view');
        expect(write!.url.hasQuery, isFalse);
      });
    }

    test(
        'thousands of songs, duplicates and odd characters arrive whole and '
        'in order', () async {
      http.Request? write;
      final client = _client(MockClient((http.Request request) async {
        if (isLookup(request)) return extensions(<String>['formPost']);
        write = request;
        return _ok(<String, dynamic>{
          'playlist': <String, dynamic>{'id': 'p-new'},
        });
      }));
      final List<String> songs = <String>[
        'a b+c&d=e',
        'café/%25%',
        '\u{1F3B5}#?;',
        'same',
        'same',
        ...manySongs(3000),
        'a b+c&d=e',
      ];
      const String name = 'Rock & Roll = 100% \u{1F3B8} +live?';

      await client.createPlaylist(_session, name: name, songIds: songs);

      final Map<String, List<String>> form =
          Uri(query: write!.body).queryParametersAll;
      expect(form['songId'], songs);
      expect(form['name'], <String>[name]);
    });

    test('a malformed extension list is a no, not a crash', () async {
      int lookups = 0;
      final List<http.Request> writes = <http.Request>[];
      final client = _client(MockClient((http.Request request) async {
        if (isLookup(request)) {
          lookups++;
          return _ok(<String, dynamic>{
            'openSubsonicExtensions': <Object?>[
              null,
              3,
              'formPost',
              <String, dynamic>{'name': 'formPost'},
              <String, dynamic>{'name': 'formPost', 'versions': '1'},
              <String, dynamic>{
                'name': 'formPost',
                'versions': <String>['1'],
              },
            ],
          });
        }
        writes.add(request);
        return _ok(<String, dynamic>{});
      }));

      await client.setPlaylistSongs(_session, 'p-1', manySongs(400));
      await client.setPlaylistSongs(_session, 'p-2', manySongs(400));

      expect(lookups, 1);
      expect(writes.map((http.Request w) => w.method), <String>['GET', 'GET']);
    });

    test('a small edit does not wait on a lookup that is still out', () async {
      final Completer<http.Response> pending = Completer<http.Response>();
      final List<http.Request> writes = <http.Request>[];
      final client = _client(MockClient((http.Request request) async {
        if (isLookup(request)) return pending.future;
        writes.add(request);
        return _ok(<String, dynamic>{});
      }));

      final Future<void> long =
          client.setPlaylistSongs(_session, 'p-1', manySongs(400));
      await pumpEventQueue();
      await client.setPlaylistSongs(_session, 'p-2', manySongs(3));

      expect(writes.single.method, 'GET');
      expect(writes.single.url.queryParameters['playlistId'], 'p-2');

      pending.complete(extensions(<String>['formPost']));
      await long;
      expect(writes.last.method, 'POST');
    });

    test(
        'behind an address that redirects, a long write still arrives whole '
        '(a real HTTP client, which follows redirects for GET only)', () async {
      final HttpServer server =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final List<String> handled = <String>[];
      server.listen((HttpRequest request) async {
        final String path = request.uri.path;
        if (path.startsWith('/old/')) {
          // The configured address moved, the way an http-to-https or
          // canonical-host redirect does.
          request.response
            ..statusCode = HttpStatus.movedPermanently
            ..headers.set(
              HttpHeaders.locationHeader,
              request.uri.replace(path: path.replaceFirst('/old/', '/new/')),
            );
          await request.response.close();
          return;
        }
        final String body = await utf8.decoder.bind(request).join();
        final Map<String, List<String>> params = <String, List<String>>{
          ...request.uri.queryParametersAll,
          ...Uri(query: body).queryParametersAll,
        };
        late final Map<String, dynamic> data;
        if (path.endsWith('/getOpenSubsonicExtensions.view')) {
          data = <String, dynamic>{
            'openSubsonicExtensions': <Map<String, dynamic>>[
              <String, dynamic>{
                'name': 'formPost',
                'versions': <int>[1],
              },
            ],
          };
        } else {
          handled
              .add('${request.method} $path ${params['songId']?.length ?? 0}');
          data = <String, dynamic>{};
        }
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(<String, dynamic>{
            'subsonic-response': <String, dynamic>{'status': 'ok', ...data},
          }));
        await request.response.close();
      });
      final SubsonicSession session = SubsonicSession(
        baseUrl: 'http://127.0.0.1:${server.port}/old',
        username: 'alice',
        salt: 'salt1',
        token: 'tok1',
      );
      final HttpSubsonicClient client = HttpSubsonicClient();

      await client.setPlaylistSongs(session, 'p-1', manySongs(400));
      expect(handled, <String>['GET /new/rest/createPlaylist.view 400']);

      // The address it moved to answers directly, so there it is a form post.
      await client.setPlaylistSongs(
        SubsonicSession(
          baseUrl: 'http://127.0.0.1:${server.port}/new',
          username: 'alice',
          salt: 'salt1',
          token: 'tok1',
        ),
        'p-1',
        manySongs(400),
      );
      expect(handled.last, 'POST /new/rest/createPlaylist.view 400');
    });

    test('an empty playlist stays one GET, with no songs and no lookup',
        () async {
      final List<http.Request> requests = <http.Request>[];
      final client = _client(MockClient((http.Request request) async {
        requests.add(request);
        return _ok(<String, dynamic>{});
      }));

      await client.setPlaylistSongs(_session, 'p-1', const <String>[]);

      expect(requests, hasLength(1));
      expect(requests.single.method, 'GET');
      expect(requests.single.url.queryParameters['playlistId'], 'p-1');
      expect(requests.single.url.queryParametersAll['songId'], isNull);
    });
  });
}
