import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/sources/plex/http_plex_tv_client.dart';
import 'package:linthra/core/sources/plex/plex_client.dart';
import 'package:linthra/core/sources/plex/plex_exception.dart';
import 'package:linthra/core/sources/plex/plex_tv_api.dart';

const String _accountToken = 'super-secret-account-token';

const PlexClientIdentity _identity = PlexClientIdentity(
  clientIdentifier: 'install-uuid-1',
  product: 'Linthra',
  version: '0.1.5',
  platform: 'Android',
  device: 'Pixel',
);

HttpPlexTvClient _client(MockClient mock) =>
    HttpPlexTvClient(identity: _identity, httpClient: mock);

/// A JSON 200 response with the usual content type.
http.Response _json(Object body, {int status = 200}) => http.Response(
      jsonEncode(body),
      status,
      headers: const <String, String>{'content-type': 'application/json'},
    );

void main() {
  group('createPin', () {
    test('POSTs /api/v2/pins?strong=true and parses the pin', () async {
      http.Request? captured;
      final HttpPlexTvClient client = _client(MockClient((r) async {
        captured = r;
        return _json(const <String, dynamic>{
          'id': 123456,
          'code': 'abcDEF123',
          'expiresIn': 1800,
          'authToken': null,
        });
      }));

      final PlexPin pin = await client.createPin();

      expect(pin.id, 123456);
      expect(pin.code, 'abcDEF123');
      expect(captured!.method, 'POST');
      expect(captured!.url.host, 'plex.tv');
      expect(captured!.url.path, '/api/v2/pins');
      expect(captured!.url.queryParameters['strong'], 'true');
    });

    test('sends Accept JSON and the identity headers — and no token', () async {
      http.Request? captured;
      final HttpPlexTvClient client = _client(MockClient((r) async {
        captured = r;
        return _json(const <String, dynamic>{'id': 1, 'code': 'c'});
      }));

      await client.createPin();

      final Map<String, String> headers = captured!.headers;
      // `package:http` lower-cases header names.
      expect(headers['accept'], 'application/json');
      expect(headers['x-plex-client-identifier'], 'install-uuid-1');
      expect(headers['x-plex-product'], 'Linthra');
      // Minting a PIN is the first step of *obtaining* a token: none exists.
      expect(headers.containsKey('x-plex-token'), isFalse);
    });

    test('treats a body without id/code as unusable', () async {
      final HttpPlexTvClient client = _client(
        MockClient(
            (_) async => _json(const <String, dynamic>{'trusted': false})),
      );

      await expectLater(
        client.createPin(),
        throwsA(isA<PlexException>()
            .having((e) => e.kind, 'kind', PlexErrorKind.unexpected)),
      );
    });

    test('maps a transport failure to a friendly plex.tv message', () async {
      final HttpPlexTvClient client = _client(
        MockClient((_) async => throw http.ClientException('refused')),
      );

      await expectLater(
        client.createPin(),
        throwsA(isA<PlexException>()
            .having((e) => e.kind, 'kind', PlexErrorKind.notReachable)
            .having((e) => e.message, 'message', contains('plex.tv'))),
      );
    });
  });

  group('checkPin', () {
    test('returns null while approval is pending', () async {
      final HttpPlexTvClient client = _client(MockClient((_) async => _json(
            const <String, dynamic>{'id': 1, 'code': 'c', 'authToken': null},
          )));

      expect(await client.checkPin(1), isNull);
    });

    test('returns the granted token once approved', () async {
      http.Request? captured;
      final HttpPlexTvClient client = _client(MockClient((r) async {
        captured = r;
        return _json(const <String, dynamic>{
          'id': 1,
          'code': 'c',
          'authToken': _accountToken,
        });
      }));

      expect(await client.checkPin(1), _accountToken);
      expect(captured!.method, 'GET');
      expect(captured!.url.path, '/api/v2/pins/1');
    });

    test('treats an empty authToken as still pending', () async {
      final HttpPlexTvClient client = _client(MockClient((_) async => _json(
            const <String, dynamic>{'id': 1, 'code': 'c', 'authToken': ''},
          )));

      expect(await client.checkPin(1), isNull);
    });

    test('maps a 404 to "sign-in expired" — definitive, not retryable',
        () async {
      final HttpPlexTvClient client =
          _client(MockClient((_) async => http.Response('', 404)));

      await expectLater(
        client.checkPin(1),
        throwsA(isA<PlexException>()
            .having((e) => e.kind, 'kind', PlexErrorKind.unauthorized)
            .having((e) => e.message, 'message', contains('expired'))),
      );
    });
  });

  group('fetchResources', () {
    test('GETs /api/v2/resources with the token in the header only', () async {
      http.Request? captured;
      final HttpPlexTvClient client = _client(MockClient((r) async {
        captured = r;
        return _json(const <Object?>[]);
      }));

      await client.fetchResources(token: _accountToken);

      expect(captured!.url.path, '/api/v2/resources');
      expect(captured!.url.queryParameters['includeHttps'], '1');
      expect(captured!.url.queryParameters['includeRelay'], '1');
      // The token rides in the header — the URL stays token-free.
      expect(captured!.headers['x-plex-token'], _accountToken);
      expect(captured!.url.toString(), isNot(contains(_accountToken)));
    });

    test('parses the bare JSON array of devices, skipping malformed ones',
        () async {
      final HttpPlexTvClient client = _client(MockClient((_) async => _json(
            const <Object?>[
              <String, dynamic>{
                'name': 'Office Server',
                'clientIdentifier': 'machine-abc',
                'provides': 'server',
                'accessToken': 'scoped-token',
                'connections': <Object?>[
                  <String, dynamic>{
                    'uri': 'https://x.plex.direct:32400',
                    'local': false,
                    'relay': false,
                  },
                ],
              },
              <String, dynamic>{'name': 'no identifier'},
              'garbage',
            ],
          )));

      final List<PlexResource> resources =
          await client.fetchResources(token: _accountToken);

      expect(resources, hasLength(1));
      expect(resources.single.name, 'Office Server');
      expect(resources.single.accessToken, 'scoped-token');
      expect(resources.single.connections.single.uri,
          'https://x.plex.direct:32400');
    });

    test('treats a non-array body as unusable', () async {
      final HttpPlexTvClient client = _client(
        MockClient((_) async => _json(const <String, dynamic>{'error': 'x'})),
      );

      await expectLater(
        client.fetchResources(token: _accountToken),
        throwsA(isA<PlexException>()
            .having((e) => e.kind, 'kind', PlexErrorKind.unexpected)),
      );
    });

    test('maps 401 to a sign-in rejection', () async {
      final HttpPlexTvClient client =
          _client(MockClient((_) async => http.Response('', 401)));

      await expectLater(
        client.fetchResources(token: 'revoked'),
        throwsA(isA<PlexException>()
            .having((e) => e.kind, 'kind', PlexErrorKind.unauthorized)),
      );
    });
  });

  group('fetchHomeUsers', () {
    test('GETs /api/v2/home/users with the token in the header only', () async {
      http.Request? captured;
      final HttpPlexTvClient client = _client(MockClient((r) async {
        captured = r;
        return _json(const <String, dynamic>{'users': <Object?>[]});
      }));

      await client.fetchHomeUsers(token: _accountToken);

      expect(captured!.method, 'GET');
      expect(captured!.url.path, '/api/v2/home/users');
      expect(captured!.headers['x-plex-token'], _accountToken);
      expect(captured!.url.toString(), isNot(contains(_accountToken)));
    });

    test('parses the users array, skipping malformed entries', () async {
      final HttpPlexTvClient client = _client(MockClient((_) async => _json(
            const <String, dynamic>{
              'users': <Object?>[
                <String, dynamic>{
                  'id': 1,
                  'uuid': 'uuid-owner',
                  'title': 'Dad',
                  'admin': true,
                  'protected': true,
                },
                <String, dynamic>{'title': 'no uuid'}, // unusable
                'garbage',
              ],
            },
          )));

      final List<PlexHomeUser> users =
          await client.fetchHomeUsers(token: _accountToken);

      expect(users, hasLength(1));
      expect(users.single.uuid, 'uuid-owner');
      expect(users.single.title, 'Dad');
      expect(users.single.admin, isTrue);
      expect(users.single.protected, isTrue);
    });

    test('tolerates a bare array envelope', () async {
      final HttpPlexTvClient client = _client(MockClient((_) async => _json(
            const <Object?>[
              <String, dynamic>{'uuid': 'u1', 'title': 'A'},
            ],
          )));

      final List<PlexHomeUser> users =
          await client.fetchHomeUsers(token: _accountToken);
      expect(users.single.uuid, 'u1');
    });

    test('treats a non-list users field as unusable', () async {
      final HttpPlexTvClient client = _client(
        MockClient(
            (_) async => _json(const <String, dynamic>{'users': 'nope'})),
      );

      await expectLater(
        client.fetchHomeUsers(token: _accountToken),
        throwsA(isA<PlexException>()
            .having((e) => e.kind, 'kind', PlexErrorKind.unexpected)),
      );
    });
  });

  group('switchHomeUser', () {
    test('POSTs the switch and returns the granted token', () async {
      http.Request? captured;
      final HttpPlexTvClient client = _client(MockClient((r) async {
        captured = r;
        return _json(const <String, dynamic>{
          'uuid': 'uuid-kid',
          'authToken': 'kid-scoped-token',
        });
      }));

      final String token = await client.switchHomeUser(
        uuid: 'uuid-kid',
        token: _accountToken,
        pin: '1234',
      );

      expect(token, 'kid-scoped-token');
      expect(captured!.method, 'POST');
      expect(captured!.url.path, '/api/v2/home/users/uuid-kid/switch');
      expect(captured!.url.queryParameters['pin'], '1234');
      // The account (owner) token authorizes the switch via the header.
      expect(captured!.headers['x-plex-token'], _accountToken);
    });

    test('a 401 (wrong/missing pin) maps to an unauthorized rejection',
        () async {
      final HttpPlexTvClient client =
          _client(MockClient((_) async => http.Response('', 401)));

      await expectLater(
        client.switchHomeUser(uuid: 'uuid-kid', token: _accountToken),
        throwsA(isA<PlexException>()
            .having((e) => e.kind, 'kind', PlexErrorKind.unauthorized)),
      );
    });

    test('a 2xx switch with no token is unusable', () async {
      final HttpPlexTvClient client = _client(
        MockClient(
            (_) async => _json(const <String, dynamic>{'uuid': 'uuid-kid'})),
      );

      await expectLater(
        client.switchHomeUser(uuid: 'uuid-kid', token: _accountToken),
        throwsA(isA<PlexException>()
            .having((e) => e.kind, 'kind', PlexErrorKind.unexpected)),
      );
    });
  });

  group('token safety', () {
    test('every failure path throws a token-free message', () async {
      final List<MockClient> failures = <MockClient>[
        MockClient((_) async => http.Response('', 401)),
        MockClient((_) async => http.Response('', 404)),
        MockClient((_) async => http.Response('', 500)),
        MockClient((_) async => http.Response('<html>nope</html>', 200)),
        MockClient((_) async => _json(const <String, dynamic>{})),
        MockClient((_) async => throw http.ClientException('boom')),
      ];

      for (final MockClient mock in failures) {
        final HttpPlexTvClient client = _client(mock);
        try {
          await client.fetchResources(token: _accountToken);
          fail('expected a PlexException');
        } on PlexException catch (error) {
          expect(error.message, isNot(contains(_accountToken)));
          expect(error.toString(), isNot(contains(_accountToken)));
        }
      }
    });

    test('a failed home-user switch never echoes the account token', () async {
      final List<MockClient> failures = <MockClient>[
        MockClient((_) async => http.Response('', 401)),
        MockClient((_) async => http.Response('', 500)),
        MockClient((_) async => throw http.ClientException('boom')),
      ];

      for (final MockClient mock in failures) {
        final HttpPlexTvClient client = _client(mock);
        try {
          await client.switchHomeUser(uuid: 'u', token: _accountToken);
          fail('expected a PlexException');
        } on PlexException catch (error) {
          expect(error.message, isNot(contains(_accountToken)));
          expect(error.toString(), isNot(contains(_accountToken)));
        }
      }
    });

    test('non-JSON pin bodies fail without echoing content', () async {
      final HttpPlexTvClient client = _client(
        MockClient((_) async =>
            http.Response('<pin secret="leaky-body-content"/>', 200)),
      );

      try {
        await client.createPin();
        fail('expected a PlexException');
      } on PlexException catch (error) {
        expect(error.message, isNot(contains('leaky-body-content')));
      }
    });
  });
}
