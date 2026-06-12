import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/sources/jellyfin/http_jellyfin_client.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';

const String _base = 'https://music.example.com';

const _session = JellyfinSession(
  baseUrl: _base,
  userId: 'user-1',
  accessToken: 'tok-abc',
  deviceId: 'device-1',
);

HttpJellyfinClient _client(MockClient mock) =>
    HttpJellyfinClient(httpClient: mock);

void main() {
  group('fetchServerInfo', () {
    test('parses public info and calls the right endpoint', () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'ServerName': 'Home',
            'Version': '10.9.0',
            'Id': 'abc',
            'ProductName': 'Jellyfin Server',
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }));

      final info = await client.fetchServerInfo(_base);

      expect(info.serverName, 'Home');
      expect(info.version, '10.9.0');
      expect(info.productName, 'Jellyfin Server');
      expect(captured!.method, 'GET');
      expect(captured!.url.path, '/System/Info/Public');
    });

    test('decodes a UTF-8 body without a charset header', () async {
      // A server sending raw UTF-8 bytes and no charset: `response.body` would
      // mis-decode this as latin1; the client decodes bodyBytes as UTF-8.
      final client = _client(MockClient((_) async {
        return http.Response.bytes(
          utf8.encode(jsonEncode(<String, dynamic>{
            'ServerName': 'Café Münchén',
            'Version': '10.9.0',
          })),
          200,
        );
      }));

      final info = await client.fetchServerInfo(_base);

      expect(info.serverName, 'Café Münchén');
    });

    test('treats an HTML/non-JSON body as "not a Jellyfin server"', () async {
      final client = _client(
        MockClient((_) async => http.Response('<html>Cloudflare</html>', 200)),
      );

      await expectLater(
        client.fetchServerInfo(_base),
        throwsA(isA<JellyfinException>().having(
          (JellyfinException e) => e.kind,
          'kind',
          JellyfinErrorKind.notJellyfin,
        )),
      );
    });

    test('maps a 404 to "not a Jellyfin server"', () async {
      final client =
          _client(MockClient((_) async => http.Response('nope', 404)));

      await expectLater(
        client.fetchServerInfo(_base),
        throwsA(isA<JellyfinException>().having(
          (JellyfinException e) => e.kind,
          'kind',
          JellyfinErrorKind.notJellyfin,
        )),
      );
    });

    test('maps a 5xx to a server error', () async {
      final client =
          _client(MockClient((_) async => http.Response('bad gateway', 502)));

      await expectLater(
        client.fetchServerInfo(_base),
        throwsA(isA<JellyfinException>().having(
          (JellyfinException e) => e.kind,
          'kind',
          JellyfinErrorKind.serverError,
        )),
      );
    });

    test('maps a transport failure to "not reachable"', () async {
      final client = _client(
        MockClient((_) async => throw http.ClientException('connection lost')),
      );

      await expectLater(
        client.fetchServerInfo(_base),
        throwsA(isA<JellyfinException>().having(
          (JellyfinException e) => e.kind,
          'kind',
          JellyfinErrorKind.notReachable,
        )),
      );
    });
  });

  group('authenticateByName', () {
    test('posts credentials and parses the token', () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'AccessToken': 'tok-xyz',
            'User': <String, dynamic>{'Id': 'u-1', 'Name': 'Alice'},
            'ServerId': 's-1',
          }),
          200,
        );
      }));

      final result = await client.authenticateByName(
        baseUrl: _base,
        username: 'alice',
        password: 'pw-secret',
        deviceId: 'dev-1',
      );

      expect(result.accessToken, 'tok-xyz');
      expect(result.userId, 'u-1');
      expect(result.userName, 'Alice');
      expect(captured!.method, 'POST');
      expect(captured!.url.path, '/Users/AuthenticateByName');
      expect(captured!.headers['Authorization'], startsWith('MediaBrowser '));
      expect(captured!.headers['Authorization'], contains('DeviceId="dev-1"'));

      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['Username'], 'alice');
      expect(body['Pw'], 'pw-secret');
    });

    test('maps 401 to unauthorized without leaking the password', () async {
      final client = _client(
        MockClient((_) async => http.Response('Unauthorized', 401)),
      );

      await expectLater(
        client.authenticateByName(
          baseUrl: _base,
          username: 'alice',
          password: 'pw-supersecret',
          deviceId: 'dev-1',
        ),
        throwsA(isA<JellyfinException>()
            .having(
              (JellyfinException e) => e.kind,
              'kind',
              JellyfinErrorKind.unauthorized,
            )
            .having(
              (JellyfinException e) => e.toString(),
              'message',
              isNot(contains('pw-supersecret')),
            )),
      );
    });
  });

  group('fetchItems', () {
    test('lists audio items from /Items with the token header', () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'Items': <dynamic>[
              <String, dynamic>{
                'Id': 't1',
                'Name': 'One',
                'RunTimeTicks': 2400000000,
              },
              <String, dynamic>{'Id': 't2', 'Name': 'Two'},
            ],
            'TotalRecordCount': 2,
          }),
          200,
        );
      }));

      final items =
          await client.fetchItems(_session, kind: JellyfinItemKind.audio);

      expect(items.map((JellyfinItemDto i) => i.id).toList(), <String>[
        't1',
        't2',
      ]);
      expect(captured!.url.path, '/Items');
      expect(captured!.url.queryParameters['IncludeItemTypes'], 'Audio');
      expect(captured!.url.queryParameters['UserId'], 'user-1');
      expect(captured!.headers['Authorization'], contains('Token="tok-abc"'));
    });

    test('uses the dedicated /Artists endpoint for artists', () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, dynamic>{'Items': <dynamic>[]}),
          200,
        );
      }));

      await client.fetchItems(_session, kind: JellyfinItemKind.artist);

      expect(captured!.url.path, '/Artists');
    });

    test('returns an empty list when the body has no Items', () async {
      final client = _client(
        MockClient(
            (_) async => http.Response(jsonEncode(<String, dynamic>{}), 200)),
      );

      final items =
          await client.fetchItems(_session, kind: JellyfinItemKind.album);

      expect(items, isEmpty);
    });

    test('maps an expired token (401) to unauthorized', () async {
      final client = _client(MockClient((_) async => http.Response('no', 401)));

      await expectLater(
        client.fetchItems(_session, kind: JellyfinItemKind.audio),
        throwsA(isA<JellyfinException>().having(
          (JellyfinException e) => e.kind,
          'kind',
          JellyfinErrorKind.unauthorized,
        )),
      );
    });
  });

  group('verifySession', () {
    test('calls /Users/Me with the token header', () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, dynamic>{'Id': 'user-1'}),
          200,
        );
      }));

      await client.verifySession(_session);

      expect(captured!.method, 'GET');
      expect(captured!.url.path, '/Users/Me');
      expect(captured!.headers['Authorization'], contains('Token="tok-abc"'));
    });

    test('maps a 401 to unauthorized (an expired token)', () async {
      final client = _client(MockClient((_) async => http.Response('no', 401)));

      await expectLater(
        client.verifySession(_session),
        throwsA(isA<JellyfinException>().having(
          (JellyfinException e) => e.kind,
          'kind',
          JellyfinErrorKind.unauthorized,
        )),
      );
    });

    test('maps a transport failure to "not reachable"', () async {
      final client = _client(
        MockClient((_) async => throw http.ClientException('offline')),
      );

      await expectLater(
        client.verifySession(_session),
        throwsA(isA<JellyfinException>().having(
          (JellyfinException e) => e.kind,
          'kind',
          JellyfinErrorKind.notReachable,
        )),
      );
    });
  });

  group('probeStream', () {
    final streamUrl =
        Uri.parse('$_base/Audio/t1/stream?static=true&api_key=tok');

    test('sends a tiny ranged GET and reports status + content type', () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return http.Response('', 206, headers: <String, String>{
          'content-type': 'audio/mpeg',
        });
      }));

      final probe = await client.probeStream(streamUrl);

      expect(probe.statusCode, 206);
      expect(probe.contentType, 'audio/mpeg');
      expect(probe.isAudio, isTrue);
      expect(probe.isHtml, isFalse);
      expect(captured!.method, 'GET');
      // A bounded range, so the whole track isn't downloaded just to check it.
      expect(captured!.headers['Range'], 'bytes=0-1');
      // Auth rides in the URL (mirroring the engine); no Authorization header.
      expect(captured!.headers.containsKey('Authorization'), isFalse);
    });

    test('returns a non-2xx status instead of throwing', () async {
      final client = _client(MockClient((_) async => http.Response('no', 401)));

      final probe = await client.probeStream(streamUrl);

      expect(probe.statusCode, 401);
    });

    test('reports an HTML content type (a Cloudflare page)', () async {
      final client = _client(MockClient((_) async => http.Response(
            '<html>Attention Required</html>',
            200,
            headers: <String, String>{
              'content-type': 'text/html; charset=utf-8'
            },
          )));

      final probe = await client.probeStream(streamUrl);

      expect(probe.isHtml, isTrue);
      expect(probe.isAudio, isFalse);
    });

    test('maps a transport failure to "not reachable"', () async {
      final client = _client(
        MockClient((_) async => throw http.ClientException('offline')),
      );

      await expectLater(
        client.probeStream(streamUrl),
        throwsA(isA<JellyfinException>().having(
          (JellyfinException e) => e.kind,
          'kind',
          JellyfinErrorKind.notReachable,
        )),
      );
    });
  });

  group('fetchLyrics', () {
    test('parses synced + plain lines and targets the lyrics endpoint',
        () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'Lyrics': <Map<String, dynamic>>[
              <String, dynamic>{'Text': 'First line', 'Start': 10000000},
              <String, dynamic>{'Text': 'Second line'},
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }));

      final lyrics = await client.fetchLyrics(_session, 'item-7');

      expect(captured!.method, 'GET');
      expect(captured!.url.path, '/Audio/item-7/Lyrics');
      expect(
        lyrics!.lines.map((line) => line.text),
        <String>['First line', 'Second line'],
      );
      // 10,000,000 ticks (100-ns units) is exactly one second.
      expect(lyrics.lines.first.start, const Duration(seconds: 1));
      expect(lyrics.lines.last.start, isNull);
      expect(lyrics.isSynced, isTrue);
    });

    test('returns null when the server has no lyrics (404)', () async {
      final client = _client(MockClient((_) async => http.Response('', 404)));

      expect(await client.fetchLyrics(_session, 'item-7'), isNull);
    });
  });

  group('favorites', () {
    test('fetchFavoriteIds lists favourite audio item ids', () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'Items': <Map<String, dynamic>>[
              <String, dynamic>{'Id': 'a'},
              <String, dynamic>{'Id': 'b'},
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }));

      final ids = await client.fetchFavoriteIds(_session);

      expect(ids, <String>{'a', 'b'});
      expect(captured!.url.queryParameters['Filters'], 'IsFavorite');
    });

    test('setFavorite POSTs to mark and DELETEs to clear', () async {
      final List<http.Request> requests = <http.Request>[];
      final client = _client(MockClient((http.Request request) async {
        requests.add(request);
        return http.Response('', 200);
      }));

      await client.setFavorite(_session, 'item-7', favorite: true);
      await client.setFavorite(_session, 'item-7', favorite: false);

      expect(requests[0].method, 'POST');
      expect(requests[0].url.path, '/Users/user-1/FavoriteItems/item-7');
      expect(requests[1].method, 'DELETE');
      expect(requests[1].url.path, '/Users/user-1/FavoriteItems/item-7');
    });
  });

  group('reportPlayback', () {
    test('started POSTs the start body to /Sessions/Playing', () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return http.Response('', 204);
      }));

      await client.reportPlayback(
        _session,
        itemId: 'item-7',
        event: JellyfinPlaybackEvent.started,
        position: const Duration(seconds: 1),
      );

      expect(captured!.method, 'POST');
      expect(captured!.url.path, '/Sessions/Playing');
      expect(captured!.headers['Content-Type'], startsWith('application/json'));
      final Map<String, dynamic> body =
          jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['ItemId'], 'item-7');
      // 10,000,000 ticks (100-ns units) is exactly one second.
      expect(body['PositionTicks'], 10000000);
      expect(body['IsPaused'], isFalse);
      expect(body['CanSeek'], isTrue);
      expect(body['PlayMethod'], 'DirectPlay');
    });

    test('progress and resume report the Progress endpoint, not paused',
        () async {
      final List<http.Request> requests = <http.Request>[];
      final client = _client(MockClient((http.Request request) async {
        requests.add(request);
        return http.Response('', 204);
      }));

      for (final JellyfinPlaybackEvent event in <JellyfinPlaybackEvent>[
        JellyfinPlaybackEvent.progress,
        JellyfinPlaybackEvent.resumed,
      ]) {
        await client.reportPlayback(
          _session,
          itemId: 'item-7',
          event: event,
          position: const Duration(seconds: 30),
        );
      }

      for (final http.Request request in requests) {
        expect(request.url.path, '/Sessions/Playing/Progress');
        final Map<String, dynamic> body =
            jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['IsPaused'], isFalse);
      }
    });

    test('paused reports the Progress endpoint with IsPaused', () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return http.Response('', 204);
      }));

      await client.reportPlayback(
        _session,
        itemId: 'item-7',
        event: JellyfinPlaybackEvent.paused,
        position: const Duration(seconds: 30),
      );

      expect(captured!.url.path, '/Sessions/Playing/Progress');
      final Map<String, dynamic> body =
          jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['IsPaused'], isTrue);
    });

    test(
        'stopped POSTs only the item and position to '
        '/Sessions/Playing/Stopped', () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return http.Response('', 204);
      }));

      await client.reportPlayback(
        _session,
        itemId: 'item-7',
        event: JellyfinPlaybackEvent.stopped,
        position: const Duration(minutes: 3),
      );

      expect(captured!.url.path, '/Sessions/Playing/Stopped');
      final Map<String, dynamic> body =
          jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['ItemId'], 'item-7');
      expect(
        body['PositionTicks'],
        const Duration(minutes: 3).inMicroseconds * 10,
      );
      expect(body.containsKey('IsPaused'), isFalse);
      expect(body.containsKey('PlayMethod'), isFalse);
    });

    test('the token rides in the Authorization header, never the URL',
        () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return http.Response('', 204);
      }));

      await client.reportPlayback(
        _session,
        itemId: 'item-7',
        event: JellyfinPlaybackEvent.started,
        position: Duration.zero,
      );

      expect(captured!.headers['Authorization'], contains('Token="tok-abc"'));
      expect(captured!.url.toString(), isNot(contains('tok-abc')));
      expect(captured!.url.hasQuery, isFalse);
    });

    test('maps a 401 to unauthorized (token-free)', () async {
      final client =
          _client(MockClient((_) async => http.Response('denied', 401)));

      await expectLater(
        client.reportPlayback(
          _session,
          itemId: 'item-7',
          event: JellyfinPlaybackEvent.started,
          position: Duration.zero,
        ),
        throwsA(isA<JellyfinException>()
            .having((e) => e.kind, 'kind', JellyfinErrorKind.unauthorized)
            .having((e) => e.message, 'message', isNot(contains('tok-abc')))),
      );
    });

    test('maps a transport failure to notReachable', () async {
      final client = _client(
        MockClient((_) async => throw http.ClientException('refused')),
      );

      await expectLater(
        client.reportPlayback(
          _session,
          itemId: 'item-7',
          event: JellyfinPlaybackEvent.progress,
          position: Duration.zero,
        ),
        throwsA(isA<JellyfinException>()
            .having((e) => e.kind, 'kind', JellyfinErrorKind.notReachable)),
      );
    });
  });
}
