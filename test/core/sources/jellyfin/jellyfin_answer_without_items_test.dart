// A Jellyfin answer without an `Items` list leaves the hearts and playlists
// alone.
//
// The favourites and playlist reads took a 2xx answer with no `Items` list (a
// proxy's own JSON, `{"Items": null}`, a changed shape) for "nothing there".
// SyncedFavoritesRepository then adopted that as the server's truth and
// cleared every Jellyfin heart, and a playlist refresh read every playlist as
// gone or emptied. Such an answer now fails the read, the way an unreachable
// server does; only the server's own total of 0 still reads as empty.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/repositories/remote_sync_gateway.dart';
import 'package:linthra/core/repositories/remote_sync_result.dart';
import 'package:linthra/core/sources/jellyfin/http_jellyfin_client.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/data/repositories/in_memory_favorites_store.dart';
import 'package:linthra/data/repositories/jellyfin_favorites_gateway.dart';
import 'package:linthra/data/repositories/synced_favorites_repository.dart';

const JellyfinSession _session = JellyfinSession(
  baseUrl: 'https://music.example.com',
  userId: 'user-1',
  accessToken: 'tok',
  deviceId: 'device-1',
  userName: 'alice',
);

/// Answers that carry no list of items.
const Map<String, Map<String, dynamic>> _withoutItems =
    <String, Map<String, dynamic>>{
  'no Items at all': <String, dynamic>{'TotalRecordCount': 2},
  'Items: null': <String, dynamic>{'Items': null},
  'Items as an object': <String, dynamic>{
    'Items': <String, dynamic>{'Id': 'a'},
  },
};

const Map<String, dynamic> _twoHearts = <String, dynamic>{
  'Items': <Map<String, dynamic>>[
    <String, dynamic>{'Id': 'a'},
    <String, dynamic>{'Id': 'b'},
  ],
  'TotalRecordCount': 2,
};

/// A client whose server answers every request with whatever [body] returns.
HttpJellyfinClient _answering(Object Function() body) => HttpJellyfinClient(
      httpClient: MockClient((http.Request request) async => http.Response(
            jsonEncode(body()),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          )),
    );

final Matcher _unusable = throwsA(isA<JellyfinException>().having(
  (JellyfinException e) => e.kind,
  'kind',
  JellyfinErrorKind.unsupportedResponse,
));

void main() {
  group('a favourites answer', () {
    late Object body;
    late SyncedFavoritesRepository favorites;

    setUp(() async {
      body = _twoHearts;
      favorites = SyncedFavoritesRepository(
        store: InMemoryFavoritesStore(),
        gateways: <RemoteFavoritesGateway>[
          JellyfinFavoritesGateway(
            client: _answering(() => body),
            session: () => _session,
          ),
        ],
      );
      addTearDown(favorites.dispose);
      expect((await favorites.refreshFromRemote()).favoriteCount, 2);
    });

    for (final MapEntry<String, Map<String, dynamic>> answer
        in _withoutItems.entries) {
      test('with ${answer.key} keeps the hearts', () async {
        body = answer.value;
        final FavoritesSyncResult second = await favorites.refreshFromRemote();

        expect(second.didSync, isFalse);
        expect(favorites.isFavorite('jellyfin:a'), isTrue);
        expect(favorites.isFavorite('jellyfin:b'), isTrue);
      });
    }

    test('of no favourites, by the server\'s own count, clears them', () async {
      body = <String, dynamic>{'TotalRecordCount': 0};
      final FavoritesSyncResult second = await favorites.refreshFromRemote();

      expect(second.didSync, isTrue);
      expect(favorites.isFavorite('jellyfin:a'), isFalse);
      expect(favorites.isFavorite('jellyfin:b'), isFalse);
    });
  });

  group('the playlist reads', () {
    for (final MapEntry<String, Map<String, dynamic>> answer
        in _withoutItems.entries) {
      test('fail on an answer with ${answer.key}', () async {
        final HttpJellyfinClient client = _answering(() => answer.value);

        await expectLater(client.fetchPlaylists(_session), _unusable);
        await expectLater(
          client.fetchPlaylistEntries(_session, 'pl-1'),
          _unusable,
        );
      });
    }

    test('read an empty list as empty', () async {
      final HttpJellyfinClient client = _answering(
        () => <String, dynamic>{'Items': <Object>[], 'TotalRecordCount': 0},
      );

      expect(await client.fetchPlaylists(_session), isEmpty);
      expect(await client.fetchPlaylistEntries(_session, 'pl-1'), isEmpty);
    });
  });
}
