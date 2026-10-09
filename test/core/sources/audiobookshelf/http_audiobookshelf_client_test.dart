import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/audiobookshelf_session.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_exception.dart';
import 'package:linthra/core/sources/audiobookshelf/http_audiobookshelf_client.dart';

const String _base = 'https://audiobooks.example.com';

const _session = AudiobookshelfSession(
  baseUrl: _base,
  userId: 'user-1',
  accessToken: 'tok-abc',
);

HttpAudiobookshelfClient _client(MockClient mock) =>
    HttpAudiobookshelfClient(httpClient: mock);

http.Response _json(Map<String, dynamic> body, {int status = 200}) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: <String, String>{'content-type': 'application/json'},
    );

void main() {
  group('fetchServerStatus', () {
    test('parses status and calls the right endpoint', () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return _json(<String, dynamic>{
          'app': 'audiobookshelf',
          'serverVersion': '2.19.0',
          'isInit': true,
        });
      }));

      final status = await client.fetchServerStatus(_base);

      expect(status.serverVersion, '2.19.0');
      expect(status.isInitialized, isTrue);
      expect(captured!.method, 'GET');
      expect(captured!.url.path, '/status');
    });

    test('decodes a UTF-8 body without a charset header', () async {
      // A server sending raw UTF-8 bytes and no charset: `response.body`
      // would mis-decode this as latin1; the client decodes bodyBytes as
      // UTF-8. Nothing in /status is actually non-ASCII, but this exercises
      // the same decode path every response goes through.
      final client = _client(MockClient((_) async {
        return http.Response.bytes(
          utf8.encode(jsonEncode(<String, dynamic>{
            'app': 'audiobookshelf',
            'serverVersion': '2.19.0',
          })),
          200,
        );
      }));

      final status = await client.fetchServerStatus(_base);
      expect(status.serverVersion, '2.19.0');
    });

    test(
        'accepts a pre-v2.6.0 server, which sends neither app nor '
        'serverVersion', () async {
      // Confirmed against the real /status handler at release tags v2.2.0
      // and v2.5.0: only isInit (and, from v2.5.0, language) was sent before
      // app/serverVersion were added in v2.6.0. A server still running one
      // of those versions must not be rejected as "not Audiobookshelf".
      final client = _client(MockClient((_) async {
        return _json(<String, dynamic>{'isInit': true, 'language': 'en-us'});
      }));

      final status = await client.fetchServerStatus(_base);

      expect(status.isInitialized, isTrue);
      expect(status.serverVersion, isNull);
    });

    test('throws notAudiobookshelf when app is not "audiobookshelf"', () async {
      final client = _client(MockClient((_) async {
        return _json(<String, dynamic>{
          'app': 'something-else',
          'serverVersion': '1.0.0',
        });
      }));

      expect(
        () => client.fetchServerStatus(_base),
        throwsA(
          isA<AudiobookshelfException>().having(
            (AudiobookshelfException e) => e.kind,
            'kind',
            AudiobookshelfErrorKind.notAudiobookshelf,
          ),
        ),
      );
    });

    test(
        'throws notAudiobookshelf on a non-JSON body (e.g. an HTML error '
        'page)', () async {
      final client = _client(MockClient((_) async {
        return http.Response('<html>not found</html>', 200);
      }));

      expect(
        () => client.fetchServerStatus(_base),
        throwsA(isA<AudiobookshelfException>()),
      );
    });

    test('maps a 5xx to serverError', () async {
      final client = _client(MockClient((_) async {
        return http.Response('', 503);
      }));

      expect(
        () => client.fetchServerStatus(_base),
        throwsA(
          isA<AudiobookshelfException>().having(
            (AudiobookshelfException e) => e.kind,
            'kind',
            AudiobookshelfErrorKind.serverError,
          ),
        ),
      );
    });
  });

  group('authenticateByName', () {
    test('sends the right body/headers and parses the result', () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return _json(<String, dynamic>{
          'user': <String, dynamic>{
            'id': 'user-1',
            'username': 'jon',
            'accessToken': 'tok-abc',
            'refreshToken': 'refresh-xyz',
          },
          'userDefaultLibraryId': 'lib-1',
        });
      }));

      final result = await client.authenticateByName(
        baseUrl: _base,
        username: 'jon',
        password: 'hunter2',
      );

      expect(result.userId, 'user-1');
      expect(result.accessToken, 'tok-abc');
      expect(result.refreshToken, 'refresh-xyz');
      expect(result.userName, 'jon');
      expect(result.defaultLibraryId, 'lib-1');

      expect(captured!.method, 'POST');
      expect(captured!.url.path, '/login');
      expect(captured!.headers['x-return-tokens'], 'true');
      final Map<String, dynamic> sentBody =
          jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(sentBody['username'], 'jon');
      expect(sentBody['password'], 'hunter2');
    });

    test(
        'signs in to a server older than 2.26, which only sends the '
        'non-expiring token', () async {
      // The login answer of 2.25.1 and everything before it: accessToken and
      // refreshToken only arrived in 2.26.0.
      final client = _client(MockClient((_) async {
        return _json(<String, dynamic>{
          'user': <String, dynamic>{
            'id': 'user-1',
            'username': 'jon',
            'token': 'legacy-jwt',
          },
          'userDefaultLibraryId': 'lib-1',
        });
      }));

      final result = await client.authenticateByName(
        baseUrl: _base,
        username: 'jon',
        password: 'hunter2',
      );

      expect(result.accessToken, 'legacy-jwt');
      expect(result.refreshToken, isNull);
      expect(result.defaultLibraryId, 'lib-1');
    });

    test('uses accessToken when a server sends the old token beside it',
        () async {
      // 2.26.0 and later still send the old token next to the new pair.
      final client = _client(MockClient((_) async {
        return _json(<String, dynamic>{
          'user': <String, dynamic>{
            'id': 'user-1',
            'username': 'jon',
            'token': 'legacy-jwt',
            'accessToken': 'tok-abc',
            'refreshToken': 'refresh-xyz',
          },
        });
      }));

      final result = await client.authenticateByName(
        baseUrl: _base,
        username: 'jon',
        password: 'hunter2',
      );

      expect(result.accessToken, 'tok-abc');
      expect(result.refreshToken, 'refresh-xyz');
    });

    test('a missing refreshToken is null, not an error (cookie-only flow)',
        () async {
      final client = _client(MockClient((_) async {
        return _json(<String, dynamic>{
          'user': <String, dynamic>{
            'id': 'user-1',
            'username': 'jon',
            'accessToken': 'tok-abc',
          },
        });
      }));

      final result = await client.authenticateByName(
        baseUrl: _base,
        username: 'jon',
        password: 'hunter2',
      );
      expect(result.refreshToken, isNull);
    });

    test('rejected credentials map to unauthorized', () async {
      final client = _client(MockClient((_) async {
        return http.Response('', 401);
      }));

      expect(
        () => client.authenticateByName(
          baseUrl: _base,
          username: 'jon',
          password: 'wrong',
        ),
        throwsA(
          isA<AudiobookshelfException>().having(
            (AudiobookshelfException e) => e.kind,
            'kind',
            AudiobookshelfErrorKind.unauthorized,
          ),
        ),
      );
    });
  });

  group('refreshTokens', () {
    test('trades the refresh token in through a header and reads the new pair',
        () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        // The refresh answer has the login response's shape, including the
        // old never-expiring token a 2.26+ server still sends.
        return _json(<String, dynamic>{
          'user': <String, dynamic>{
            'id': 'user-1',
            'username': 'jon',
            'token': 'old-style',
            'accessToken': 'tok-new',
            'refreshToken': 'refresh-new',
          },
          'userDefaultLibraryId': 'lib-1',
        });
      }));

      final result = await client.refreshTokens(
        baseUrl: _base,
        refreshToken: 'refresh-old',
      );

      expect(result.userId, 'user-1');
      expect(result.accessToken, 'tok-new');
      expect(result.refreshToken, 'refresh-new');
      expect(captured!.method, 'POST');
      expect(captured!.url.path, '/auth/refresh');
      expect(captured!.headers['x-refresh-token'], 'refresh-old');
      // Never in the URL, and no stale bearer token alongside.
      expect(captured!.url.toString(), isNot(contains('refresh-old')));
      expect(captured!.headers.containsKey('Authorization'), isFalse);
    });

    test('a refused refresh token is a 401 that carries no token', () async {
      final client = _client(MockClient((_) async {
        return _json(<String, dynamic>{'error': 'Invalid refresh token'},
            status: 401);
      }));

      Object? caught;
      try {
        await client.refreshTokens(baseUrl: _base, refreshToken: 'refresh-old');
      } catch (error) {
        caught = error;
      }

      expect(
        caught,
        isA<AudiobookshelfException>()
            .having((AudiobookshelfException e) => e.kind, 'kind',
                AudiobookshelfErrorKind.unauthorized)
            .having((AudiobookshelfException e) => e.statusCode, 'status', 401),
      );
      expect('$caught', isNot(contains('refresh-old')));
    });

    test('an answer without tokens is an unusable response, not a sign-in',
        () async {
      final client = _client(MockClient((_) async {
        return _json(<String, dynamic>{'user': <String, dynamic>{}});
      }));

      await expectLater(
        client.refreshTokens(baseUrl: _base, refreshToken: 'refresh-old'),
        throwsA(isA<AudiobookshelfException>().having(
            (AudiobookshelfException e) => e.kind,
            'kind',
            AudiobookshelfErrorKind.unexpected)),
      );
    });

    test('a rate-limited refresh is transient, not a refusal', () async {
      final client = _client(MockClient((_) async {
        return http.Response('Too many requests', 429);
      }));

      await expectLater(
        client.refreshTokens(baseUrl: _base, refreshToken: 'refresh-old'),
        throwsA(isA<AudiobookshelfException>().having(
            (AudiobookshelfException e) => e.kind,
            'kind',
            AudiobookshelfErrorKind.serverError)),
      );
    });
  });

  group('fetchLibraries', () {
    test('a 403 keeps its status, so it is not taken for an expired token',
        () async {
      final client = _client(MockClient((_) async {
        return http.Response('Forbidden', 403);
      }));

      await expectLater(
        client.fetchLibraries(_session),
        throwsA(isA<AudiobookshelfException>()
            .having((AudiobookshelfException e) => e.kind, 'kind',
                AudiobookshelfErrorKind.unauthorized)
            .having(
                (AudiobookshelfException e) => e.statusCode, 'status', 403)),
      );
    });

    test('parses the libraries array and sends the bearer token', () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return _json(<String, dynamic>{
          'libraries': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'lib-1',
              'name': 'Audiobooks',
              'mediaType': 'book',
            },
            <String, dynamic>{
              'id': 'lib-2',
              'name': 'Podcasts',
              'mediaType': 'podcast',
            },
          ],
        });
      }));

      final libraries = await client.fetchLibraries(_session);

      expect(libraries, hasLength(2));
      expect(libraries[0].id, 'lib-1');
      expect(libraries[0].name, 'Audiobooks');
      expect(libraries[0].mediaType, 'book');
      expect(captured!.headers['Authorization'], 'Bearer tok-abc');
      expect(captured!.url.path, '/api/libraries');
    });

    test('skips a malformed entry instead of failing the whole listing',
        () async {
      final client = _client(MockClient((_) async {
        return _json(<String, dynamic>{
          'libraries': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'lib-1', 'name': 'Audiobooks'},
            <String, dynamic>{'name': 'missing id'},
          ],
        });
      }));

      final libraries = await client.fetchLibraries(_session);
      expect(libraries, hasLength(1));
      expect(libraries.single.id, 'lib-1');
    });

    test('an unrecognized shape returns an empty list, not an error', () async {
      final client = _client(MockClient((_) async {
        return _json(<String, dynamic>{'somethingElse': true});
      }));

      final libraries = await client.fetchLibraries(_session);
      expect(libraries, isEmpty);
    });
  });

  group('fetchLibraryItems', () {
    Map<String, dynamic> book({
      String id = 'item-1',
      String title = 'The Hobbit',
    }) {
      return <String, dynamic>{
        'id': id,
        'mediaType': 'book',
        'media': <String, dynamic>{
          'duration': 40230.5,
          'metadata': <String, dynamic>{
            'title': title,
            'subtitle': 'or There and Back Again',
            'authorName': 'J. R. R. Tolkien',
            'narratorName': 'Rob Inglis',
            'seriesName': 'Middle-earth',
          },
        },
      };
    }

    test('parses a page, and asks for a minified, title-sorted page', () async {
      http.Request? captured;
      final client = _client(MockClient((http.Request request) async {
        captured = request;
        return _json(<String, dynamic>{
          'results': <Map<String, dynamic>>[book()],
          'total': 42,
          'page': 0,
        });
      }));

      final page = await client.fetchLibraryItems(
        _session,
        libraryId: 'lib-1',
        limit: 100,
        page: 0,
      );

      expect(page.total, 42);
      expect(page.page, 0);
      expect(page.items, hasLength(1));
      final item = page.items.single;
      expect(item.id, 'item-1');
      expect(item.title, 'The Hobbit');
      expect(item.subtitle, 'or There and Back Again');
      expect(item.authorName, 'J. R. R. Tolkien');
      expect(item.narratorName, 'Rob Inglis');
      expect(item.seriesName, 'Middle-earth');
      expect(item.duration, const Duration(milliseconds: 40230500));

      expect(captured!.headers['Authorization'], 'Bearer tok-abc');
      expect(captured!.url.path, '/api/libraries/lib-1/items');
      expect(captured!.url.queryParameters, <String, String>{
        'minified': '1',
        'sort': 'media.metadata.title',
        'desc': '0',
        'limit': '100',
        'page': '0',
      });
    });

    test('reads the full (non-minified) author/narrator/series shape too',
        () async {
      // A response that sends the objects rather than the pre-joined names:
      // the parser must not depend on the query string staying as it is.
      final client = _client(MockClient((_) async {
        return _json(<String, dynamic>{
          'results': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'item-1',
              'media': <String, dynamic>{
                'metadata': <String, dynamic>{
                  'title': 'Good Omens',
                  'authors': <Map<String, dynamic>>[
                    <String, dynamic>{'id': 'a1', 'name': 'Terry Pratchett'},
                    <String, dynamic>{'id': 'a2', 'name': 'Neil Gaiman'},
                  ],
                  'narrators': <String>['Martin Jarvis'],
                  'series': <Map<String, dynamic>>[
                    <String, dynamic>{'id': 's1', 'name': 'Discworld'},
                  ],
                },
              },
            },
          ],
          'total': 1,
        });
      }));

      final page = await client.fetchLibraryItems(
        _session,
        libraryId: 'lib-1',
        limit: 100,
        page: 0,
      );

      final item = page.items.single;
      expect(item.authorName, 'Terry Pratchett, Neil Gaiman');
      expect(item.narratorName, 'Martin Jarvis');
      expect(item.seriesName, 'Discworld');
      // Nothing reported a length: no invented 0:00.
      expect(item.duration, isNull);
    });

    test('skips an entry with no title instead of failing the page', () async {
      final client = _client(MockClient((_) async {
        return _json(<String, dynamic>{
          'results': <Map<String, dynamic>>[
            book(),
            // Scanned but not yet identified: no metadata title.
            <String, dynamic>{'id': 'item-2', 'media': <String, dynamic>{}},
          ],
          'total': 2,
        });
      }));

      final page = await client.fetchLibraryItems(
        _session,
        libraryId: 'lib-1',
        limit: 100,
        page: 0,
      );

      expect(page.items, hasLength(1));
      expect(page.items.single.id, 'item-1');
      // The server's own count is kept: it counts the book that was skipped.
      expect(page.total, 2);
      // And so does the raw count, which is what says how far through the
      // library this page read.
      expect(page.rawCount, 2);
    });

    test('an unrecognized shape is an empty page, not an error', () async {
      final client = _client(MockClient((_) async {
        return _json(<String, dynamic>{'somethingElse': true});
      }));

      final page = await client.fetchLibraryItems(
        _session,
        libraryId: 'lib-1',
        limit: 100,
        page: 2,
      );

      expect(page.items, isEmpty);
      expect(page.rawCount, 0);
      expect(page.total, 0);
      // No page echoed back: the one that was asked for.
      expect(page.page, 2);
    });

    test('a rejected token surfaces as unauthorized', () async {
      final client = _client(MockClient((_) async {
        return _json(<String, dynamic>{'error': 'nope'}, status: 401);
      }));

      await expectLater(
        client.fetchLibraryItems(
          _session,
          libraryId: 'lib-1',
          limit: 100,
          page: 0,
        ),
        throwsA(
          isA<AudiobookshelfException>().having(
            (AudiobookshelfException e) => e.kind,
            'kind',
            AudiobookshelfErrorKind.unauthorized,
          ),
        ),
      );
    });

    test('a non-ASCII title survives a body with no charset header', () async {
      final client = _client(MockClient((_) async {
        return http.Response.bytes(
          utf8.encode(jsonEncode(<String, dynamic>{
            'results': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'item-1',
                'media': <String, dynamic>{
                  'metadata': <String, dynamic>{
                    'title': 'L\u2019\u00c9tranger',
                    'authorName': 'Albert Camus',
                  },
                },
              },
            ],
            'total': 1,
          })),
          200,
        );
      }));

      final page = await client.fetchLibraryItems(
        _session,
        libraryId: 'lib-1',
        limit: 100,
        page: 0,
      );

      expect(page.items.single.title, 'L\u2019\u00c9tranger');
    });
  });
}
