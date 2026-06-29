import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/diagnostics/safe_event_log.dart';
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

/// A client tuned for the paging/retry tests: tiny page size and zero waits so
/// pagination and bounded retry are exercised without real delays.
HttpJellyfinClient _itemsClient(
  MockClient mock, {
  int pageSize = 500,
  int attempts = 3,
  int maxPages = 10000,
}) =>
    HttpJellyfinClient(
      httpClient: mock,
      itemPageSize: pageSize,
      maxItemFetchAttempts: attempts,
      maxItemPages: maxPages,
      retryBackoff: Duration.zero,
      pageGap: Duration.zero,
    );

http.Response _jsonItems(List<Map<String, dynamic>> items, {int? total}) =>
    http.Response(
      jsonEncode(<String, dynamic>{
        'Items': items,
        if (total != null) 'TotalRecordCount': total,
      }),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );

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

      final listing =
          await client.fetchItems(_session, kind: JellyfinItemKind.audio);

      expect(listing.items.map((JellyfinItemDto i) => i.id).toList(), <String>[
        't1',
        't2',
      ]);
      expect(listing.skippedCount, 0);
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

      final listing =
          await client.fetchItems(_session, kind: JellyfinItemKind.album);

      expect(listing.items, isEmpty);
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

  group('fetchItems pagination', () {
    test('pages through the library until TotalRecordCount and concatenates',
        () async {
      final List<int> starts = <int>[];
      final client = _itemsClient(
        MockClient((http.Request request) async {
          final int start =
              int.parse(request.url.queryParameters['StartIndex'] ?? '0');
          starts.add(start);
          if (start == 0) {
            return _jsonItems(<Map<String, dynamic>>[
              <String, dynamic>{'Id': 't1', 'Name': 'One'},
              <String, dynamic>{'Id': 't2', 'Name': 'Two'},
            ], total: 3);
          }
          return _jsonItems(<Map<String, dynamic>>[
            <String, dynamic>{'Id': 't3', 'Name': 'Three'},
          ], total: 3);
        }),
        pageSize: 2,
      );

      final listing =
          await client.fetchItems(_session, kind: JellyfinItemKind.audio);

      expect(
        listing.items.map((JellyfinItemDto i) => i.id).toList(),
        <String>['t1', 't2', 't3'],
      );
      // Exactly two pages — it didn't loop past the total or stop early.
      expect(starts, <int>[0, 2]);
      // The page size rides in the request.
      expect(listing.skippedCount, 0);
    });

    test('stops on a short final page when the server gives no total',
        () async {
      int calls = 0;
      final client = _itemsClient(
        MockClient((http.Request request) async {
          calls++;
          final int start =
              int.parse(request.url.queryParameters['StartIndex'] ?? '0');
          if (start == 0) {
            return _jsonItems(<Map<String, dynamic>>[
              <String, dynamic>{'Id': 't1', 'Name': 'One'},
              <String, dynamic>{'Id': 't2', 'Name': 'Two'},
            ]);
          }
          // A short page (1 < pageSize) signals the end.
          return _jsonItems(<Map<String, dynamic>>[
            <String, dynamic>{'Id': 't3', 'Name': 'Three'},
          ]);
        }),
        pageSize: 2,
      );

      final listing =
          await client.fetchItems(_session, kind: JellyfinItemKind.audio);

      expect(listing.items, hasLength(3));
      expect(calls, 2);
    });

    test('a single full page with no total stops after one empty next page',
        () async {
      // Exactly pageSize items and no total: the client fetches one more page to
      // be sure, gets an empty one, and stops — never an infinite loop.
      int calls = 0;
      final client = _itemsClient(
        MockClient((http.Request request) async {
          calls++;
          final int start =
              int.parse(request.url.queryParameters['StartIndex'] ?? '0');
          if (start == 0) {
            return _jsonItems(<Map<String, dynamic>>[
              <String, dynamic>{'Id': 't1', 'Name': 'One'},
              <String, dynamic>{'Id': 't2', 'Name': 'Two'},
            ]);
          }
          return _jsonItems(const <Map<String, dynamic>>[]);
        }),
        pageSize: 2,
      );

      final listing =
          await client.fetchItems(_session, kind: JellyfinItemKind.audio);

      expect(listing.items, hasLength(2));
      expect(calls, 2);
    });

    test('a persistent failure on a later page aborts (no truncated listing)',
        () async {
      // The headline durability guarantee: if page 1 succeeds but a later page
      // fails for good, fetchItems THROWS rather than returning the partial
      // page-1 items — so the caller keeps the previous catalog instead of
      // committing a truncated library.
      final client = _itemsClient(
        MockClient((http.Request request) async {
          final int start =
              int.parse(request.url.queryParameters['StartIndex'] ?? '0');
          if (start == 0) {
            return _jsonItems(<Map<String, dynamic>>[
              <String, dynamic>{'Id': 't1', 'Name': 'One'},
              <String, dynamic>{'Id': 't2', 'Name': 'Two'},
            ], total: 4);
          }
          // The second page is down for good (outlives the retry budget).
          return http.Response('down', 500);
        }),
        pageSize: 2,
        attempts: 2,
      );

      await expectLater(
        client.fetchItems(_session, kind: JellyfinItemKind.audio),
        throwsA(isA<JellyfinException>().having(
          (JellyfinException e) => e.kind,
          'kind',
          JellyfinErrorKind.serverError,
        )),
      );
    });

    test('a server that ignores paging is bounded by the page-count backstop',
        () async {
      // Pathological server: always returns a full page and never a total, so
      // only the backstop can stop the loop. It must stop after exactly maxPages
      // requests rather than spinning forever.
      int calls = 0;
      final client = _itemsClient(
        MockClient((http.Request request) async {
          calls++;
          return _jsonItems(<Map<String, dynamic>>[
            <String, dynamic>{'Id': 't1', 'Name': 'One'},
            <String, dynamic>{'Id': 't2', 'Name': 'Two'},
          ]);
        }),
        pageSize: 2,
        maxPages: 3,
      );

      final listing =
          await client.fetchItems(_session, kind: JellyfinItemKind.audio);

      // Exactly maxPages requests, then it stopped.
      expect(calls, 3);
      expect(listing.items.length, greaterThan(0));
    });
  });

  group('fetchItems item tolerance', () {
    test('skips an unparseable item in a page, keeps the rest, counts the skip',
        () async {
      final client = _itemsClient(
        MockClient((_) async => _jsonItems(<Map<String, dynamic>>[
              <String, dynamic>{'Id': 't1', 'Name': 'One'},
              // No Name → unusable → skipped (counted).
              <String, dynamic>{'Id': 'bad'},
              // Wrong-typed Album → still usable → kept (Album dropped).
              <String, dynamic>{'Id': 't3', 'Name': 'Three', 'Album': 123},
            ], total: 3)),
      );

      final listing =
          await client.fetchItems(_session, kind: JellyfinItemKind.audio);

      expect(
        listing.items.map((JellyfinItemDto i) => i.id).toList(),
        <String>['t1', 't3'],
      );
      expect(listing.skippedCount, 1);
      // The kept item with a bad field has the field dropped, not a crash.
      expect(listing.items.last.album, isNull);
    });

    test('a non-object entry in the Items array is skipped, not fatal',
        () async {
      final client = _itemsClient(
        MockClient((_) async => http.Response(
              jsonEncode(<String, dynamic>{
                'Items': <dynamic>[
                  'a bare string, not an object',
                  <String, dynamic>{'Id': 't1', 'Name': 'One'},
                ],
                'TotalRecordCount': 2,
              }),
              200,
            )),
      );

      final listing =
          await client.fetchItems(_session, kind: JellyfinItemKind.audio);

      expect(listing.items.single.id, 't1');
      expect(listing.skippedCount, 1);
    });

    test('a real skip emits a secret-free diagnostics breadcrumb', () async {
      SafeEventLog.instance.clear();
      addTearDown(SafeEventLog.instance.clear);

      final client = _itemsClient(
        MockClient((_) async => _jsonItems(<Map<String, dynamic>>[
              <String, dynamic>{'Id': 't1', 'Name': 'One'},
              <String, dynamic>{'Id': 'bad'}, // no Name → skipped
            ], total: 2)),
      );

      await client.fetchItems(_session, kind: JellyfinItemKind.audio);

      // The skip is recorded end-to-end (kind + counts only — no title/url).
      expect(
        SafeEventLog.instance.lines,
        contains('jellyfin-sync: skip:audio dropped=1 kept=1'),
      );
    });
  });

  group('fetchItems retry + backoff', () {
    test('retries a transient 5xx, then succeeds', () async {
      int calls = 0;
      final client = _itemsClient(
        MockClient((_) async {
          calls++;
          if (calls == 1) return http.Response('busy', 503);
          return _jsonItems(<Map<String, dynamic>>[
            <String, dynamic>{'Id': 't1', 'Name': 'One'},
          ], total: 1);
        }),
      );

      final listing =
          await client.fetchItems(_session, kind: JellyfinItemKind.audio);

      expect(listing.items.single.id, 't1');
      expect(calls, 2);
    });

    test('retries a transient transport failure, then succeeds', () async {
      int calls = 0;
      final client = _itemsClient(
        MockClient((_) async {
          calls++;
          if (calls == 1) throw http.ClientException('connection reset');
          return _jsonItems(<Map<String, dynamic>>[
            <String, dynamic>{'Id': 't1', 'Name': 'One'},
          ], total: 1);
        }),
      );

      final listing =
          await client.fetchItems(_session, kind: JellyfinItemKind.audio);

      expect(listing.items.single.id, 't1');
      expect(calls, 2);
    });

    test('gives up after the attempt budget on a persistent 5xx', () async {
      int calls = 0;
      final client = _itemsClient(
        MockClient((_) async {
          calls++;
          return http.Response('still down', 500);
        }),
        attempts: 3,
      );

      await expectLater(
        client.fetchItems(_session, kind: JellyfinItemKind.audio),
        throwsA(isA<JellyfinException>().having(
          (JellyfinException e) => e.kind,
          'kind',
          JellyfinErrorKind.serverError,
        )),
      );
      // Bounded: it tried exactly the budget, not forever.
      expect(calls, 3);
    });

    test('gives up after the attempt budget on a persistent transport failure',
        () async {
      int calls = 0;
      final client = _itemsClient(
        MockClient((_) async {
          calls++;
          throw http.ClientException('offline');
        }),
        attempts: 3,
      );

      await expectLater(
        client.fetchItems(_session, kind: JellyfinItemKind.audio),
        throwsA(isA<JellyfinException>().having(
          (JellyfinException e) => e.kind,
          'kind',
          JellyfinErrorKind.notReachable,
        )),
      );
      expect(calls, 3);
    });

    test('retries a 429 rate-limit, then succeeds', () async {
      int calls = 0;
      final client = _itemsClient(
        MockClient((_) async {
          calls++;
          if (calls == 1) return http.Response('slow down', 429);
          return _jsonItems(<Map<String, dynamic>>[
            <String, dynamic>{'Id': 't1', 'Name': 'One'},
          ], total: 1);
        }),
      );

      final listing =
          await client.fetchItems(_session, kind: JellyfinItemKind.audio);

      expect(listing.items.single.id, 't1');
      expect(calls, 2);
    });

    test('retries a 408 request-timeout, then succeeds', () async {
      int calls = 0;
      final client = _itemsClient(
        MockClient((_) async {
          calls++;
          if (calls == 1) return http.Response('timeout', 408);
          return _jsonItems(<Map<String, dynamic>>[
            <String, dynamic>{'Id': 't1', 'Name': 'One'},
          ], total: 1);
        }),
      );

      final listing =
          await client.fetchItems(_session, kind: JellyfinItemKind.audio);

      expect(listing.items.single.id, 't1');
      expect(calls, 2);
    });

    test('does NOT retry a 404 — a non-retryable client status', () async {
      int calls = 0;
      final client = _itemsClient(
        MockClient((_) async {
          calls++;
          return http.Response('nope', 404);
        }),
        attempts: 3,
      );

      await expectLater(
        client.fetchItems(_session, kind: JellyfinItemKind.audio),
        throwsA(isA<JellyfinException>().having(
          (JellyfinException e) => e.kind,
          'kind',
          JellyfinErrorKind.notJellyfin,
        )),
      );
      expect(calls, 1);
    });

    test('a persistent 429 rate-limit surfaces as a (transient) server error',
        () async {
      // After exhausting retries, a 429/408 must read as a transient server
      // error (→ "try again later"), not "doesn't look like a Jellyfin server".
      final client = _itemsClient(
        MockClient((_) async => http.Response('slow down', 429)),
        attempts: 2,
      );

      await expectLater(
        client.fetchItems(_session, kind: JellyfinItemKind.audio),
        throwsA(isA<JellyfinException>().having(
          (JellyfinException e) => e.kind,
          'kind',
          JellyfinErrorKind.serverError,
        )),
      );
    });

    test('runs the real (non-zero) exponential backoff path between retries',
        () async {
      // Exercises `_backoff` (the 1<<(attempt-2) shift + the awaited delay) with
      // a non-zero base, which the zero-backoff helper otherwise skips. Tiny
      // delays keep it fast; the point is the path runs and still succeeds.
      int calls = 0;
      final client = HttpJellyfinClient(
        httpClient: MockClient((_) async {
          calls++;
          if (calls < 3) return http.Response('busy', 503);
          return _jsonItems(<Map<String, dynamic>>[
            <String, dynamic>{'Id': 't1', 'Name': 'One'},
          ], total: 1);
        }),
        maxItemFetchAttempts: 3,
        retryBackoff: const Duration(milliseconds: 1),
        pageGap: Duration.zero,
      );

      final listing =
          await client.fetchItems(_session, kind: JellyfinItemKind.audio);

      expect(listing.items.single.id, 't1');
      expect(calls, 3);
    });

    test('does NOT retry a 401 — auth is the server\'s settled answer',
        () async {
      int calls = 0;
      final client = _itemsClient(
        MockClient((_) async {
          calls++;
          return http.Response('denied', 401);
        }),
        attempts: 3,
      );

      await expectLater(
        client.fetchItems(_session, kind: JellyfinItemKind.audio),
        throwsA(isA<JellyfinException>().having(
          (JellyfinException e) => e.kind,
          'kind',
          JellyfinErrorKind.unauthorized,
        )),
      );
      // One attempt only: retrying an auth failure is pointless.
      expect(calls, 1);
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
