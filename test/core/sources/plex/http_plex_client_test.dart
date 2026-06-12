import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/sources/plex/http_plex_client.dart';
import 'package:linthra/core/sources/plex/plex_api.dart';
import 'package:linthra/core/sources/plex/plex_client.dart';
import 'package:linthra/core/sources/plex/plex_endpoints.dart';
import 'package:linthra/core/sources/plex/plex_exception.dart';

const String _base = 'https://plex.example.com:32400';
const String _token = 'super-secret-plex-token';

const PlexClientIdentity _identity = PlexClientIdentity(
  clientIdentifier: 'install-uuid-1',
  product: 'Linthra',
  version: '0.1.5',
  platform: 'Android',
  device: 'Pixel',
);

HttpPlexClient _client(MockClient mock, {int pageSize = 200}) =>
    HttpPlexClient(identity: _identity, httpClient: mock, pageSize: pageSize);

/// A JSON 200 response with the usual content type.
http.Response _json(Map<String, dynamic> body) => http.Response(
      jsonEncode(body),
      200,
      headers: const <String, String>{'content-type': 'application/json'},
    );

void main() {
  group('fetchIdentity', () {
    test('parses identity and calls /identity', () async {
      http.Request? captured;
      final HttpPlexClient client = _client(MockClient((http.Request r) async {
        captured = r;
        return _json(<String, dynamic>{
          'MediaContainer': <String, dynamic>{
            'machineIdentifier': 'abc123def',
            'version': '1.40.2.8395',
          },
        });
      }));

      final PlexServerIdentity identity =
          await client.fetchIdentity(baseUrl: _base, token: _token);

      expect(identity.machineIdentifier, 'abc123def');
      expect(identity.version, '1.40.2.8395');
      expect(captured!.method, 'GET');
      expect(captured!.url.path, '/identity');
    });

    test('sends Accept JSON, the token header, and the identity headers',
        () async {
      http.Request? captured;
      final HttpPlexClient client = _client(MockClient((http.Request r) async {
        captured = r;
        return _json(<String, dynamic>{
          'MediaContainer': <String, dynamic>{'machineIdentifier': 'm'},
        });
      }));

      await client.fetchIdentity(baseUrl: _base, token: _token);

      final Map<String, String> headers = captured!.headers;
      // `package:http` lower-cases header names.
      expect(headers['accept'], 'application/json');
      expect(headers['x-plex-token'], _token);
      expect(headers['x-plex-client-identifier'], 'install-uuid-1');
      expect(headers['x-plex-product'], 'Linthra');
      expect(headers['x-plex-version'], '0.1.5');
      expect(headers['x-plex-platform'], 'Android');
      expect(headers['x-plex-device'], 'Pixel');
      // The friendly player name a PMS dashboard displays for this client.
      expect(headers['x-plex-device-name'], 'Pixel');
    });

    test('treats a body without machineIdentifier as "not a Plex server"',
        () async {
      final HttpPlexClient client = _client(MockClient((_) async => _json(
            <String, dynamic>{
              'MediaContainer': <String, dynamic>{'version': '1.40'},
            },
          )));

      await expectLater(
        client.fetchIdentity(baseUrl: _base, token: _token),
        throwsA(isA<PlexException>().having(
          (PlexException e) => e.kind,
          'kind',
          PlexErrorKind.notPlex,
        )),
      );
    });

    test('treats an XML/non-JSON body as "not a Plex server"', () async {
      // Plex defaults to XML; without a JSON Accept an old server may still
      // answer XML. The client asks for JSON, so any non-JSON body is a failure.
      final HttpPlexClient client = _client(MockClient(
        (_) async => http.Response(
          '<MediaContainer machineIdentifier="abc"/>',
          200,
          headers: const <String, String>{'content-type': 'application/xml'},
        ),
      ));

      await expectLater(
        client.fetchIdentity(baseUrl: _base, token: _token),
        throwsA(isA<PlexException>().having(
          (PlexException e) => e.kind,
          'kind',
          PlexErrorKind.notPlex,
        )),
      );
    });

    test('decodes a UTF-8 body without a charset header', () async {
      final HttpPlexClient client = _client(MockClient((_) async {
        return http.Response.bytes(
          utf8.encode(jsonEncode(<String, dynamic>{
            'MediaContainer': <String, dynamic>{
              'machineIdentifier': 'm',
              'version': 'Café 1.0',
            },
          })),
          200,
        );
      }));

      final PlexServerIdentity identity =
          await client.fetchIdentity(baseUrl: _base, token: _token);
      expect(identity.version, 'Café 1.0');
    });
  });

  group('fetchSections', () {
    test('returns every section (music + non-music) from /library/sections',
        () async {
      http.Request? captured;
      final HttpPlexClient client = _client(MockClient((http.Request r) async {
        captured = r;
        return _json(<String, dynamic>{
          'MediaContainer': <String, dynamic>{
            'Directory': <dynamic>[
              <String, dynamic>{'key': '3', 'title': 'Music', 'type': 'artist'},
              <String, dynamic>{'key': '1', 'title': 'Movies', 'type': 'movie'},
            ],
          },
        });
      }));

      final List<PlexDirectory> sections =
          await client.fetchSections(baseUrl: _base, token: _token);

      expect(captured!.url.path, '/library/sections');
      expect(sections, hasLength(2));
      expect(sections.first.isMusic, isTrue);
      expect(sections[1].isMusic, isFalse);
    });

    test('throws notPlex when the body has no MediaContainer', () async {
      final HttpPlexClient client =
          _client(MockClient((_) async => _json(<String, dynamic>{})));

      await expectLater(
        client.fetchSections(baseUrl: _base, token: _token),
        throwsA(isA<PlexException>().having(
          (PlexException e) => e.kind,
          'kind',
          PlexErrorKind.notPlex,
        )),
      );
    });
  });

  group('fetchSectionItems — music types 8 / 9 / 10', () {
    test('artists request type=8 on the section listing path', () async {
      http.Request? captured;
      final HttpPlexClient client = _client(MockClient((http.Request r) async {
        captured = r;
        return _json(<String, dynamic>{
          'MediaContainer': <String, dynamic>{
            'size': 1,
            'Metadata': <dynamic>[
              <String, dynamic>{
                'ratingKey': '50',
                'type': 'artist',
                'title': 'Boards of Canada',
              },
            ],
          },
        });
      }));

      final List<PlexMetadata> artists = await client.fetchSectionItems(
        baseUrl: _base,
        token: _token,
        sectionKey: '3',
        itemType: PlexMetadataType.artist,
      );

      expect(captured!.url.path, '/library/sections/3/all');
      expect(captured!.url.queryParameters[PlexEndpoints.typeParam], '8');
      expect(artists.single.ratingKey, '50');
      expect(artists.single.metadataType, PlexMetadataType.artist);
    });

    test('albums request type=9', () async {
      http.Request? captured;
      final HttpPlexClient client = _client(MockClient((http.Request r) async {
        captured = r;
        return _json(<String, dynamic>{
          'MediaContainer': <String, dynamic>{
            'size': 0,
            'Metadata': <dynamic>[]
          },
        });
      }));

      await client.fetchSectionItems(
        baseUrl: _base,
        token: _token,
        sectionKey: '3',
        itemType: PlexMetadataType.album,
      );

      expect(captured!.url.queryParameters[PlexEndpoints.typeParam], '9');
    });

    test('tracks request type=10', () async {
      http.Request? captured;
      final HttpPlexClient client = _client(MockClient((http.Request r) async {
        captured = r;
        return _json(<String, dynamic>{
          'MediaContainer': <String, dynamic>{
            'size': 0,
            'Metadata': <dynamic>[]
          },
        });
      }));

      await client.fetchSectionItems(
        baseUrl: _base,
        token: _token,
        sectionKey: '3',
        itemType: PlexMetadataType.track,
      );

      expect(captured!.url.queryParameters[PlexEndpoints.typeParam], '10');
    });
  });

  group('fetchSectionItems — pagination', () {
    test('walks every page via X-Plex-Container-Start until totalSize is met',
        () async {
      final List<String?> requestedStarts = <String?>[];
      final List<String?> requestedSizes = <String?>[];
      // pageSize 2: page 0 returns items 1+2, page 1 returns item 3 (last).
      final HttpPlexClient client =
          _client(pageSize: 2, MockClient((http.Request r) async {
        requestedStarts
            .add(r.url.queryParameters[PlexEndpoints.containerStartParam]);
        requestedSizes
            .add(r.url.queryParameters[PlexEndpoints.containerSizeParam]);
        final int start = int.parse(
            r.url.queryParameters[PlexEndpoints.containerStartParam]!);
        if (start == 0) {
          return _json(<String, dynamic>{
            'MediaContainer': <String, dynamic>{
              'size': 2,
              'totalSize': 3,
              'offset': 0,
              'Metadata': <dynamic>[
                <String, dynamic>{'ratingKey': '1', 'type': 'track'},
                <String, dynamic>{'ratingKey': '2', 'type': 'track'},
              ],
            },
          });
        }
        return _json(<String, dynamic>{
          'MediaContainer': <String, dynamic>{
            'size': 1,
            'totalSize': 3,
            'offset': 2,
            'Metadata': <dynamic>[
              <String, dynamic>{'ratingKey': '3', 'type': 'track'},
            ],
          },
        });
      }));

      final List<PlexMetadata> tracks = await client.fetchSectionItems(
        baseUrl: _base,
        token: _token,
        sectionKey: '3',
        itemType: PlexMetadataType.track,
      );

      expect(
          tracks.map((PlexMetadata t) => t.ratingKey), <String>['1', '2', '3']);
      // Two pages: started at 0 then 2, each asking for the page size.
      expect(requestedStarts, <String>['0', '2']);
      expect(requestedSizes, <String>['2', '2']);
    });

    test('stops after a single short page (no totalSize)', () async {
      int calls = 0;
      final HttpPlexClient client =
          _client(pageSize: 200, MockClient((http.Request r) async {
        calls++;
        return _json(<String, dynamic>{
          'MediaContainer': <String, dynamic>{
            'size': 2,
            'Metadata': <dynamic>[
              <String, dynamic>{'ratingKey': '1', 'type': 'album'},
              <String, dynamic>{'ratingKey': '2', 'type': 'album'},
            ],
          },
        });
      }));

      final List<PlexMetadata> albums = await client.fetchSectionItems(
        baseUrl: _base,
        token: _token,
        sectionKey: '3',
        itemType: PlexMetadataType.album,
      );

      expect(albums, hasLength(2));
      expect(calls, 1, reason: 'a short page is the last page');
    });

    test('stops on an empty first page', () async {
      int calls = 0;
      final HttpPlexClient client =
          _client(pageSize: 2, MockClient((http.Request r) async {
        calls++;
        return _json(<String, dynamic>{
          'MediaContainer': <String, dynamic>{
            'size': 0,
            'Metadata': <dynamic>[]
          },
        });
      }));

      final List<PlexMetadata> tracks = await client.fetchSectionItems(
        baseUrl: _base,
        token: _token,
        sectionKey: '3',
        itemType: PlexMetadataType.track,
      );

      expect(tracks, isEmpty);
      expect(calls, 1);
    });
  });

  group('fetchMetadata', () {
    test('parses a single item with its Part for the play-time lookup',
        () async {
      http.Request? captured;
      final HttpPlexClient client = _client(MockClient((http.Request r) async {
        captured = r;
        return _json(<String, dynamic>{
          'MediaContainer': <String, dynamic>{
            'Metadata': <dynamic>[
              <String, dynamic>{
                'ratingKey': '123',
                'type': 'track',
                'title': 'Roygbiv',
                'Media': <dynamic>[
                  <String, dynamic>{
                    'Part': <dynamic>[
                      <String, dynamic>{
                        'key': '/library/parts/12345/167/file.flac',
                      },
                    ],
                  },
                ],
              },
            ],
          },
        });
      }));

      final PlexMetadata item = await client.fetchMetadata(
        baseUrl: _base,
        token: _token,
        ratingKey: '123',
      );

      expect(captured!.url.path, '/library/metadata/123');
      expect(item.ratingKey, '123');
      expect(item.firstPartKey, '/library/parts/12345/167/file.flac');
    });

    test('maps a 404 to notFound', () async {
      final HttpPlexClient client =
          _client(MockClient((_) async => http.Response('nope', 404)));

      await expectLater(
        client.fetchMetadata(baseUrl: _base, token: _token, ratingKey: '999'),
        throwsA(isA<PlexException>().having(
          (PlexException e) => e.kind,
          'kind',
          PlexErrorKind.notFound,
        )),
      );
    });

    test('throws unsupportedResponse when the container carries no item',
        () async {
      final HttpPlexClient client = _client(MockClient((_) async => _json(
            <String, dynamic>{
              'MediaContainer': <String, dynamic>{'Metadata': <dynamic>[]},
            },
          )));

      await expectLater(
        client.fetchMetadata(baseUrl: _base, token: _token, ratingKey: '1'),
        throwsA(isA<PlexException>().having(
          (PlexException e) => e.kind,
          'kind',
          PlexErrorKind.unsupportedResponse,
        )),
      );
    });
  });

  group('reportTimeline', () {
    Future<http.Request> report(
      http.Response response, {
      Duration? duration = const Duration(minutes: 3),
    }) async {
      http.Request? captured;
      final HttpPlexClient client = _client(MockClient((http.Request r) async {
        captured = r;
        return response;
      }));
      await client.reportTimeline(
        baseUrl: _base,
        token: _token,
        ratingKey: '4242',
        state: PlexTimelineState.paused,
        time: const Duration(seconds: 65),
        duration: duration,
      );
      return captured!;
    }

    test('GETs /:/timeline with the report params, in milliseconds', () async {
      final http.Request request = await report(http.Response('', 200));

      expect(request.method, 'GET');
      expect(request.url.path, '/:/timeline');
      expect(request.url.queryParameters[PlexEndpoints.ratingKeyParam], '4242');
      expect(request.url.queryParameters[PlexEndpoints.keyParam],
          '/library/metadata/4242');
      expect(request.url.queryParameters[PlexEndpoints.stateParam], 'paused');
      expect(request.url.queryParameters[PlexEndpoints.timeParam], '65000');
      expect(
          request.url.queryParameters[PlexEndpoints.durationParam], '180000');
    });

    test('the token rides in the header; the timeline URL is token-free',
        () async {
      final http.Request request = await report(http.Response('', 200));

      expect(request.headers['x-plex-token'], _token);
      // The identity headers (incl. the device name PMS displays) come too.
      expect(request.headers['x-plex-client-identifier'], 'install-uuid-1');
      expect(request.headers['x-plex-device-name'], 'Pixel');
      final String url = request.url.toString();
      expect(url, isNot(contains(_token)));
      expect(url.toLowerCase(), isNot(contains('x-plex-token')));
    });

    test('omits duration when unknown', () async {
      final http.Request request =
          await report(http.Response('', 200), duration: null);

      expect(
        request.url.queryParameters.containsKey(PlexEndpoints.durationParam),
        isFalse,
      );
    });

    test('tolerates any 2xx body — empty, XML, or JSON — without parsing',
        () async {
      for (final http.Response response in <http.Response>[
        http.Response('', 200),
        http.Response('<MediaContainer size="0"/>', 200),
        _json(<String, dynamic>{'MediaContainer': <String, dynamic>{}}),
      ]) {
        await expectLater(report(response), completes);
      }
    });

    test('maps failures to the usual token-free PlexException', () async {
      final Map<int, PlexErrorKind> cases = <int, PlexErrorKind>{
        401: PlexErrorKind.unauthorized,
        404: PlexErrorKind.notFound,
        500: PlexErrorKind.serverError,
      };
      for (final MapEntry<int, PlexErrorKind> entry in cases.entries) {
        final HttpPlexClient client =
            _client(MockClient((_) async => http.Response('no', entry.key)));
        try {
          await client.reportTimeline(
            baseUrl: _base,
            token: _token,
            ratingKey: '1',
            state: PlexTimelineState.playing,
            time: Duration.zero,
          );
          fail('expected a PlexException for HTTP ${entry.key}');
        } on PlexException catch (e) {
          expect(e.kind, entry.value);
          expect(e.message, isNot(contains(_token)));
          expect(e.toString(), isNot(contains(_token)));
        }
      }
    });

    test('a transport failure becomes notReachable, token-free', () async {
      final HttpPlexClient client = _client(
          MockClient((_) async => throw http.ClientException('x $_token')));

      try {
        await client.reportTimeline(
          baseUrl: _base,
          token: _token,
          ratingKey: '1',
          state: PlexTimelineState.stopped,
          time: Duration.zero,
        );
        fail('expected a PlexException');
      } on PlexException catch (e) {
        expect(e.kind, PlexErrorKind.notReachable);
        expect(e.message, isNot(contains(_token)));
        expect(e.toString(), isNot(contains(_token)));
      }
    });
  });

  group('error mapping', () {
    test('401/403 → unauthorized', () async {
      for (final int code in <int>[401, 403]) {
        final HttpPlexClient client =
            _client(MockClient((_) async => http.Response('no', code)));
        await expectLater(
          client.fetchIdentity(baseUrl: _base, token: _token),
          throwsA(isA<PlexException>().having(
            (PlexException e) => e.kind,
            'kind',
            PlexErrorKind.unauthorized,
          )),
        );
      }
    });

    test('5xx → serverError carrying the status code', () async {
      final HttpPlexClient client =
          _client(MockClient((_) async => http.Response('boom', 503)));

      await expectLater(
        client.fetchSections(baseUrl: _base, token: _token),
        throwsA(isA<PlexException>()
            .having(
                (PlexException e) => e.kind, 'kind', PlexErrorKind.serverError)
            .having((PlexException e) => e.statusCode, 'statusCode', 503)),
      );
    });

    test('a non-Plex 4xx → notPlex', () async {
      final HttpPlexClient client =
          _client(MockClient((_) async => http.Response('nope', 400)));

      await expectLater(
        client.fetchSections(baseUrl: _base, token: _token),
        throwsA(isA<PlexException>().having(
          (PlexException e) => e.kind,
          'kind',
          PlexErrorKind.notPlex,
        )),
      );
    });

    test('an HTML/non-JSON 200 body → notPlex', () async {
      final HttpPlexClient client = _client(
        MockClient((_) async => http.Response('<html>proxy error</html>', 200)),
      );

      await expectLater(
        client.fetchSections(baseUrl: _base, token: _token),
        throwsA(isA<PlexException>().having(
          (PlexException e) => e.kind,
          'kind',
          PlexErrorKind.notPlex,
        )),
      );
    });

    test('a transport failure → notReachable', () async {
      final HttpPlexClient client = _client(
        MockClient((_) async => throw http.ClientException('connection lost')),
      );

      await expectLater(
        client.fetchIdentity(baseUrl: _base, token: _token),
        throwsA(isA<PlexException>().having(
          (PlexException e) => e.kind,
          'kind',
          PlexErrorKind.notReachable,
        )),
      );
    });
  });

  group('token redaction / no leakage', () {
    test('the token rides in the X-Plex-Token header, never in the API URL',
        () async {
      http.Request? captured;
      final HttpPlexClient client = _client(MockClient((http.Request r) async {
        captured = r;
        return _json(<String, dynamic>{
          'MediaContainer': <String, dynamic>{'machineIdentifier': 'm'},
        });
      }));

      await client.fetchIdentity(baseUrl: _base, token: _token);

      // The token is sent as a header...
      expect(captured!.headers['x-plex-token'], _token);
      // ...and the URL (the thing that ends up in logs) is token-free.
      final String url = captured!.url.toString();
      expect(url, isNot(contains(_token)));
      expect(url.toLowerCase(), isNot(contains('x-plex-token')));
      // And even a hand-built "GET <url>" log line stays clean once redacted.
      expect(PlexEndpoints.redactToken('GET $url'), isNot(contains(_token)));
    });

    test('the token never appears in a thrown exception', () async {
      // Drive every error path with the real token supplied and assert none of
      // the friendly messages leak it.
      final List<MockClient> mocks = <MockClient>[
        MockClient((_) async => http.Response('no', 401)), // unauthorized
        MockClient((_) async => http.Response('boom', 500)), // serverError
        MockClient((_) async => http.Response('<html>', 200)), // notPlex
        MockClient((_) async => http.Response('no', 404)), // notFound
        MockClient((_) async => throw http.ClientException('x $_token')),
      ];

      for (final MockClient mock in mocks) {
        final HttpPlexClient client = _client(mock);
        try {
          await client.fetchMetadata(
            baseUrl: _base,
            token: _token,
            ratingKey: '1',
          );
          fail('expected a PlexException');
        } on PlexException catch (e) {
          expect(e.message, isNot(contains(_token)));
          expect(e.message.toLowerCase(), isNot(contains('x-plex-token')));
          expect(e.toString(), isNot(contains(_token)));
        }
      }
    });
  });
}
