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
