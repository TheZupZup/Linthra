import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/repositories/remote_sync_gateway.dart';
import 'package:linthra/core/sources/subsonic/subsonic_exception.dart';
import 'package:linthra/data/repositories/subsonic_favorites_gateway.dart';

import '../../core/sources/subsonic/fake_subsonic_client.dart';

const _session = SubsonicSession(
  baseUrl: 'https://music.example.com',
  username: 'alice',
  salt: 'salt1',
  token: 'tok1',
);

void main() {
  group('SubsonicFavoritesGateway', () {
    late FakeSubsonicClient client;

    setUp(() => client = FakeSubsonicClient());

    SubsonicFavoritesGateway build({SubsonicSession? session}) =>
        SubsonicFavoritesGateway(client: client, session: () => session);

    test('owns the subsonic: scheme', () {
      expect(build(session: _session).uriScheme, 'subsonic:');
    });

    test('isConnected reflects the live session', () {
      expect(build(session: _session).isConnected, isTrue);
      expect(build(session: null).isConnected, isFalse);
    });

    test('fetchFavoriteUris namespaces the server starred song ids', () async {
      client.starredSongIds = <String>{'mf-1', 'mf-2'};
      final Set<String> uris =
          await build(session: _session).fetchFavoriteUris();
      expect(uris, <String>{'subsonic:mf-1', 'subsonic:mf-2'});
    });

    test('pushFavorite stars/unstars by the bare song id', () async {
      final SubsonicFavoritesGateway gateway = build(session: _session);
      await gateway.pushFavorite('subsonic:mf-9', true);
      expect(client.starCalls,
          <({String songId, bool starred})>[(songId: 'mf-9', starred: true)]);
      await gateway.pushFavorite('subsonic:mf-9', false);
      expect(client.starCalls.last, (songId: 'mf-9', starred: false));
    });

    test('a fetch failure raises a friendly RemoteSyncException', () async {
      client.favoritesError = SubsonicException.notReachable();
      await expectLater(
        () => build(session: _session).fetchFavoriteUris(),
        throwsA(isA<RemoteSyncException>()),
      );
    });

    test('a push failure raises a friendly RemoteSyncException', () async {
      client.favoritesError = SubsonicException.unauthorized();
      await expectLater(
        () => build(session: _session).pushFavorite('subsonic:mf-1', true),
        throwsA(isA<RemoteSyncException>()),
      );
    });

    test('without a session there is no request and no favourites', () async {
      final SubsonicFavoritesGateway gateway = build(session: null);
      expect(await gateway.fetchFavoriteUris(), isEmpty);
      await gateway.pushFavorite('subsonic:mf-1', true);
      expect(client.starCalls, isEmpty);
    });
  });
}
