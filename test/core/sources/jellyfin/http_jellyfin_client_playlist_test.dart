import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/sources/jellyfin/http_jellyfin_client.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';

const String _base = 'https://music.example.com';
const String _token = 'tok-abc-secret';

const JellyfinSession _session = JellyfinSession(
  baseUrl: _base,
  userId: 'user-1',
  accessToken: _token,
  deviceId: 'device-1',
);

HttpJellyfinClient _client(MockClient mock) =>
    HttpJellyfinClient(httpClient: mock);

http.Response _json(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: const <String, String>{'content-type': 'application/json'},
    );

/// A Jellyfin-shaped item id: 32 hex characters.
String _itemId(int n) => n.toRadixString(16).padLeft(32, '0');

List<String> _itemIds(int count) =>
    <String>[for (int i = 0; i < count; i++) _itemId(i)];

/// A server that takes every playlist add, recording each request.
MockClient _acceptingAdds(List<http.Request> requests) =>
    MockClient((request) async {
      requests.add(request);
      return http.Response('', 204);
    });

/// The item ids one add request carried, in order.
List<String> _sentIds(http.Request request) =>
    request.url.queryParameters['Ids']!.split(',');

/// The HTTP/1.1 request line [request] goes out with, which servers and
/// proxies cap (8 KB by default for Kestrel and nginx).
String _requestLine(http.Request request) =>
    '${request.method} ${request.url.path}?${request.url.query} HTTP/1.1';

void main() {
  group('fetchPlaylists', () {
    test('lists the user playlists from /Items', () async {
      http.Request? captured;
      final HttpJellyfinClient client = _client(MockClient((request) async {
        captured = request;
        return _json(<String, dynamic>{
          'Items': <dynamic>[
            <String, dynamic>{'Id': 'pl-1', 'Name': 'Road Trip'},
            <String, dynamic>{'Id': 'pl-2', 'Name': 'Focus'},
          ],
        });
      }));

      final List<JellyfinPlaylistDto> playlists =
          await client.fetchPlaylists(_session);

      expect(playlists.map((p) => p.name), <String>['Road Trip', 'Focus']);
      expect(captured!.method, 'GET');
      expect(captured!.url.path, '/Items');
      expect(captured!.url.queryParameters['IncludeItemTypes'], 'Playlist');
      // The token rides only in the auth header, never logged elsewhere.
      expect(captured!.headers['Authorization'], contains(_token));
    });

    test('skips a malformed playlist (numeric Id/Name), keeping the good one',
        () async {
      final HttpJellyfinClient client = _client(MockClient((request) async {
        return _json(<String, dynamic>{
          'Items': <dynamic>[
            <String, dynamic>{'Id': 123, 'Name': 'Bad'},
            <String, dynamic>{'Id': 'pl-good', 'Name': 'Good'},
          ],
        });
      }));

      final List<JellyfinPlaylistDto> playlists =
          await client.fetchPlaylists(_session);

      // The numeric-Id playlist coerces away and is skipped; the listing loop
      // does not throw, and the good playlist still loads.
      expect(playlists.map((p) => p.id), <String>['pl-good']);
    });
  });

  group('fetchPlaylistEntries', () {
    test('parses item ids and entry ids', () async {
      final HttpJellyfinClient client = _client(MockClient((request) async {
        expect(request.url.path, '/Playlists/pl-1/Items');
        return _json(<String, dynamic>{
          'Items': <dynamic>[
            <String, dynamic>{'Id': 'a', 'PlaylistItemId': 'e-a'},
            <String, dynamic>{'Id': 'b', 'PlaylistItemId': 'e-b'},
          ],
        });
      }));

      final List<JellyfinPlaylistEntry> entries =
          await client.fetchPlaylistEntries(_session, 'pl-1');
      expect(entries.map((e) => e.itemId), <String>['a', 'b']);
      expect(entries.first.playlistItemId, 'e-a');
    });

    test('skips an entry with a non-string Id, keeping the rest', () async {
      final HttpJellyfinClient client = _client(MockClient((request) async {
        return _json(<String, dynamic>{
          'Items': <dynamic>[
            <String, dynamic>{'Id': 42, 'PlaylistItemId': 'e-bad'},
            <String, dynamic>{'Id': 'b', 'PlaylistItemId': 'e-b'},
          ],
        });
      }));

      final List<JellyfinPlaylistEntry> entries =
          await client.fetchPlaylistEntries(_session, 'pl-1');
      expect(entries.map((e) => e.itemId), <String>['b']);
    });
  });

  group('createPlaylist', () {
    test('POSTs to /Playlists and returns the new id', () async {
      http.Request? captured;
      final HttpJellyfinClient client = _client(MockClient((request) async {
        captured = request;
        return _json(<String, dynamic>{'Id': 'new-pl'});
      }));

      final String id = await client.createPlaylist(
        _session,
        name: 'My Mix',
        itemIds: <String>['a', 'b'],
      );

      expect(id, 'new-pl');
      expect(captured!.method, 'POST');
      expect(captured!.url.path, '/Playlists');
      expect(captured!.url.queryParameters['Name'], 'My Mix');
      expect(captured!.url.queryParameters['Ids'], 'a,b');
      expect(captured!.url.queryParameters['UserId'], 'user-1');
    });
  });

  group('addItemsToPlaylist', () {
    test('POSTs item ids to the playlist', () async {
      http.Request? captured;
      final HttpJellyfinClient client = _client(MockClient((request) async {
        captured = request;
        return http.Response('', 204);
      }));

      await client.addItemsToPlaylist(_session, 'pl-1', <String>['x', 'y']);

      expect(captured!.method, 'POST');
      expect(captured!.url.path, '/Playlists/pl-1/Items');
      expect(captured!.url.queryParameters['Ids'], 'x,y');
    });

    test('sends nothing for an empty list', () async {
      final List<http.Request> requests = <http.Request>[];
      final HttpJellyfinClient client = _client(_acceptingAdds(requests));

      await client.addItemsToPlaylist(_session, 'pl-1', const <String>[]);

      expect(requests, isEmpty);
    });

    test('sends exactly 100 ids in one request', () async {
      final List<http.Request> requests = <http.Request>[];
      final HttpJellyfinClient client = _client(_acceptingAdds(requests));
      final List<String> ids = _itemIds(100);

      await client.addItemsToPlaylist(_session, 'pl-1', ids);

      expect(requests.map(_sentIds), <List<String>>[ids]);
    });

    test('splits 101 ids into 100 and 1, in order', () async {
      final List<http.Request> requests = <http.Request>[];
      final HttpJellyfinClient client = _client(_acceptingAdds(requests));
      final List<String> ids = _itemIds(101);

      await client.addItemsToPlaylist(_session, 'pl-1', ids);

      expect(requests.map(_sentIds), <List<String>>[
        ids.sublist(0, 100),
        ids.sublist(100),
      ]);
    });

    test(
        'sends a few hundred ids in batches that each fit an 8 KB request '
        'line (#876)', () async {
      final List<http.Request> requests = <http.Request>[];
      final HttpJellyfinClient client = _client(_acceptingAdds(requests));
      final List<String> ids = _itemIds(450);

      await client.addItemsToPlaylist(_session, 'pl-1', ids);

      expect(requests.map((r) => _sentIds(r).length), <int>[
        100,
        100,
        100,
        100,
        50,
      ]);
      expect(requests.expand(_sentIds), ids);
      for (final http.Request request in requests) {
        expect(request.method, 'POST');
        expect(request.url.path, '/Playlists/pl-1/Items');
        expect(request.url.queryParameters['UserId'], 'user-1');
        expect(_requestLine(request).length, lessThan(8192));
        // Every batch is authenticated by the header alone.
        expect(request.headers['Authorization'], contains(_token));
        expect(request.url.toString(), isNot(contains(_token)));
      }
    });

    test('keeps repeated ids and their order across a batch boundary',
        () async {
      final List<http.Request> requests = <http.Request>[];
      final HttpJellyfinClient client = _client(_acceptingAdds(requests));
      // The same song on both sides of the cut, and twice in a row.
      final List<String> ids = <String>[
        ..._itemIds(99),
        _itemId(7),
        _itemId(7),
        _itemId(3),
      ];

      await client.addItemsToPlaylist(_session, 'pl-1', ids);

      expect(requests.map((r) => _sentIds(r).length), <int>[100, 2]);
      expect(requests.expand(_sentIds), ids);
    });

    test('sends one batch at a time', () async {
      int inFlight = 0;
      int mostInFlight = 0;
      int sent = 0;
      final HttpJellyfinClient client = _client(MockClient((request) async {
        sent++;
        inFlight++;
        if (inFlight > mostInFlight) mostInFlight = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        inFlight--;
        return http.Response('', 204);
      }));

      await client.addItemsToPlaylist(_session, 'pl-1', _itemIds(350));

      expect(sent, 4);
      expect(mostInFlight, 1);
    });

    group('a later batch failing', () {
      /// Adds 250 ids (three batches) to a server that gives [secondAnswer]
      /// to the second one, returning the error and what was sent.
      Future<(JellyfinException?, List<http.Request>)> addFailingSecondBatch(
        Future<http.Response> Function() secondAnswer,
      ) async {
        final List<http.Request> requests = <http.Request>[];
        final HttpJellyfinClient client = _client(MockClient((request) async {
          requests.add(request);
          if (requests.length == 2) return secondAnswer();
          return http.Response('', 204);
        }));
        try {
          await client.addItemsToPlaylist(_session, 'pl-1', _itemIds(250));
        } on JellyfinException catch (e) {
          return (e, requests);
        }
        return (null, requests);
      }

      test('throws the server error and sends nothing after it', () async {
        final (JellyfinException? error, List<http.Request> requests) =
            await addFailingSecondBatch(
          () async => http.Response('boom', 500),
        );

        expect(error?.kind, JellyfinErrorKind.serverError);
        expect(error!.message, isNot(contains(_token)));
        // The batch that landed is never sent again (that can put its songs
        // in the playlist twice), and the one after the failure never goes.
        expect(requests.map(_sentIds), <List<String>>[
          _itemIds(250).sublist(0, 100),
          _itemIds(250).sublist(100, 200),
        ]);
      });

      test('reads a dropped connection as not reachable and stops', () async {
        final (JellyfinException? error, List<http.Request> requests) =
            await addFailingSecondBatch(
          () async => throw http.ClientException('reset'),
        );

        expect(error?.kind, JellyfinErrorKind.notReachable);
        expect(requests, hasLength(2));
      });

      test('reads an expired session as unauthorized and stops', () async {
        final (JellyfinException? error, List<http.Request> requests) =
            await addFailingSecondBatch(
          () async => http.Response('', 401),
        );

        expect(error?.kind, JellyfinErrorKind.unauthorized);
        expect(requests, hasLength(2));
      });
    });
  });

  group('removeItemsFromPlaylist', () {
    test('resolves entry ids then DELETEs them', () async {
      final List<http.Request> requests = <http.Request>[];
      final HttpJellyfinClient client = _client(MockClient((request) async {
        requests.add(request);
        if (request.method == 'GET') {
          return _json(<String, dynamic>{
            'Items': <dynamic>[
              <String, dynamic>{'Id': 'a', 'PlaylistItemId': 'e-a'},
              <String, dynamic>{'Id': 'b', 'PlaylistItemId': 'e-b'},
            ],
          });
        }
        return http.Response('', 204);
      }));

      await client.removeItemsFromPlaylist(_session, 'pl-1', <String>['b']);

      final http.Request del = requests.firstWhere((r) => r.method == 'DELETE');
      expect(del.url.path, '/Playlists/pl-1/Items');
      // Removes by the playlist *entry* id, not the media id.
      expect(del.url.queryParameters['EntryIds'], 'e-b');
    });
  });

  group('deletePlaylist', () {
    test('DELETEs the playlist item', () async {
      http.Request? captured;
      final HttpJellyfinClient client = _client(MockClient((request) async {
        captured = request;
        return http.Response('', 204);
      }));

      await client.deletePlaylist(_session, 'pl-1');
      expect(captured!.method, 'DELETE');
      expect(captured!.url.path, '/Items/pl-1');
    });
  });

  group('error mapping (secret-free)', () {
    test('401 maps to unauthorized without leaking the token', () async {
      final HttpJellyfinClient client = _client(
        MockClient((_) async => http.Response('nope', 401)),
      );

      Object? caught;
      try {
        await client.createPlaylist(_session, name: 'X');
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<JellyfinException>());
      final JellyfinException error = caught! as JellyfinException;
      expect(error.kind, JellyfinErrorKind.unauthorized);
      expect(error.message, isNot(contains(_token)));
    });

    test('a transport failure maps to notReachable, secret-free', () async {
      final HttpJellyfinClient client = _client(
        MockClient((_) async => throw http.ClientException('boom')),
      );

      Object? caught;
      try {
        await client.fetchPlaylists(_session);
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<JellyfinException>());
      final JellyfinException error = caught! as JellyfinException;
      expect(error.kind, JellyfinErrorKind.notReachable);
      expect(error.message, isNot(contains(_token)));
      expect(error.message, isNot(contains('boom')));
    });
  });
}
