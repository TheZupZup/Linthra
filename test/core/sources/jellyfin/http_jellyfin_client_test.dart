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
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }));

      final info = await client.fetchServerInfo(_base);

      expect(info.serverName, 'Home');
      expect(info.version, '10.9.0');
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
}
