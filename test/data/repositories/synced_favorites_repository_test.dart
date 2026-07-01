import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/favorites_store.dart';
import 'package:linthra/core/repositories/remote_sync_gateway.dart';
import 'package:linthra/core/repositories/remote_sync_result.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/core/sources/subsonic/subsonic_exception.dart';
import 'package:linthra/data/repositories/in_memory_favorites_store.dart';
import 'package:linthra/data/repositories/jellyfin_favorites_gateway.dart';
import 'package:linthra/data/repositories/subsonic_favorites_gateway.dart';
import 'package:linthra/data/repositories/synced_favorites_repository.dart';

import '../../core/sources/jellyfin/fake_jellyfin_client.dart';
import '../../core/sources/subsonic/fake_subsonic_client.dart';

const _subsonicSession = SubsonicSession(
  baseUrl: 'https://nav.example.com',
  username: 'alice',
  salt: 'salt1',
  token: 'tok1',
);

Track _subsonic(String id) => Track(id: id, title: id, uri: 'subsonic:$id');

const _session = JellyfinSession(
  baseUrl: 'https://music.example.com',
  userId: 'user-1',
  accessToken: 'tok',
  deviceId: 'device-1',
);

Track _jellyfin(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');
Track _local(String id) => Track(id: id, title: id, uri: 'file:///$id.mp3');

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('SyncedFavoritesRepository (Jellyfin gateway)', () {
    late InMemoryFavoritesStore store;
    late FakeJellyfinClient client;

    setUp(() {
      store = InMemoryFavoritesStore();
      client = FakeJellyfinClient();
    });

    SyncedFavoritesRepository build({JellyfinSession? session}) {
      return SyncedFavoritesRepository(
        store: store,
        gateways: <RemoteFavoritesGateway>[
          JellyfinFavoritesGateway(
            client: client,
            session: () => session,
          ),
        ],
      );
    }

    test('favoriting a Jellyfin track pushes to the server and persists',
        () async {
      final repo = build(session: _session);

      await repo.setFavorite(_jellyfin('j1'), true);

      // Tracked by the provider-namespaced uri…
      expect(repo.isFavorite('jellyfin:j1'), isTrue);
      // …but the server push still uses the bare item id.
      expect(
        client.favoriteCalls,
        <({String itemId, bool favorite})>[(itemId: 'j1', favorite: true)],
      );
      // Persisted under the (server-owned) remote set, as a uri.
      expect((await store.load()).remoteIds, <String>{'jellyfin:j1'});
    });

    test('unfavoriting a Jellyfin track deletes it on the server', () async {
      final repo = build(session: _session);
      await repo.setFavorite(_jellyfin('j1'), true);

      await repo.setFavorite(_jellyfin('j1'), false);

      expect(repo.isFavorite('jellyfin:j1'), isFalse);
      expect(client.favoriteCalls.last, (itemId: 'j1', favorite: false));
    });

    test('a local track is stored on-device and never sent to the server',
        () async {
      final repo = build(session: _session);

      await repo.setFavorite(_local('a'), true);

      expect(repo.isFavorite('file:///a.mp3'), isTrue);
      expect(client.favoriteCalls, isEmpty);
      final loaded = await store.load();
      expect(loaded.localIds, <String>{'file:///a.mp3'});
      expect(loaded.remoteIds, isEmpty);
    });

    test('favoriting one provider never favourites a same-id sibling',
        () async {
      // Only Jellyfin supports favouriting today, but the heart is keyed by uri
      // so a future provider's same-id copy can never be wrongly flagged.
      final repo = build(session: _session);

      await repo.setFavorite(_jellyfin('101'), true);

      expect(repo.isFavorite('jellyfin:101'), isTrue);
      expect(repo.isFavorite('subsonic:101'), isFalse);
    });

    test('favoritesStream emits the union of local and remote favourites',
        () async {
      final repo = build(session: _session);
      final emissions = <Set<String>>[];
      final sub = repo.favoritesStream.listen(emissions.add);
      await _settle();

      await repo.setFavorite(_local('a'), true);
      await repo.setFavorite(_jellyfin('j1'), true);
      await _settle();

      expect(emissions.last, <String>{'file:///a.mp3', 'jellyfin:j1'});
      await sub.cancel();
    });

    test('refreshFromRemote adopts the server set, keeping local favourites',
        () async {
      final repo = build(session: _session);
      await repo.setFavorite(_local('a'), true);
      // The server reports j9 as a favourite (set on another client).
      client.favoriteIds = <String>{'j9'};

      await repo.refreshFromRemote();

      expect(repo.isFavorite('file:///a.mp3'), isTrue); // local kept
      // Adopted and namespaced to the jellyfin: uri the UI keys on.
      expect(repo.isFavorite('jellyfin:j9'), isTrue);
    });

    test('refreshFromRemote reports the synced favourite count', () async {
      final repo = build(session: _session);
      client.favoriteIds = <String>{'j1', 'j2', 'j3'};

      final result = await repo.refreshFromRemote();

      expect(result.didSync, isTrue);
      expect(result.favoriteCount, 3);
    });

    test('refreshFromRemote reports not configured without a session',
        () async {
      final repo = build(session: null);

      final result = await repo.refreshFromRemote();

      expect(result.outcome, RemoteSyncOutcome.notConfigured);
    });

    test('refreshFromRemote reports a failure on a server error', () async {
      client.favoritesError = JellyfinException.notReachable();
      final repo = build(session: _session);

      final result = await repo.refreshFromRemote();

      expect(result.didFail, isTrue);
    });

    test('a server push failure keeps the optimistic local favourite',
        () async {
      client.favoritesError = JellyfinException.notReachable();
      final repo = build(session: _session);

      await repo.setFavorite(_jellyfin('j1'), true);

      // Still favourited locally despite the failed push.
      expect(repo.isFavorite('jellyfin:j1'), isTrue);
      expect((await store.load()).remoteIds, <String>{'jellyfin:j1'});
    });

    test('without a session, favourites stay purely local', () async {
      final repo = build(session: null);

      await repo.setFavorite(_jellyfin('j1'), true);
      await repo.refreshFromRemote();

      expect(repo.isFavorite('jellyfin:j1'), isTrue);
      expect(client.favoriteCalls, isEmpty);
    });

    test('loads persisted favourites from the store on first read', () async {
      store = InMemoryFavoritesStore(
        const FavoritesData(
          localIds: <String>{'file:///a.mp3'},
          remoteIds: <String>{'jellyfin:j1'},
        ),
      );
      final repo = build(session: _session);

      // The synchronous mirror is empty until the first stream read loads it.
      final ids = await repo.favoritesStream.first;

      expect(ids, <String>{'file:///a.mp3', 'jellyfin:j1'});
    });

    test('clearRemote drops server favourites but keeps on-device ones',
        () async {
      final repo = build(session: _session);
      await repo.setFavorite(_jellyfin('j1'), true); // server-synced
      await repo.setFavorite(_local('a'), true); // device-local
      expect(repo.isFavorite('jellyfin:j1'), isTrue);
      expect(repo.isFavorite('file:///a.mp3'), isTrue);

      await repo.clearRemote();

      // The remote (account) favourite is gone; the local one survives.
      expect(repo.isFavorite('jellyfin:j1'), isFalse);
      expect(repo.isFavorite('file:///a.mp3'), isTrue);
      final loaded = await store.load();
      expect(loaded.remoteIds, isEmpty);
      expect(loaded.localIds, <String>{'file:///a.mp3'});
    });

    test('clearRemote emits the reduced set on the stream', () async {
      final repo = build(session: _session);
      await repo.setFavorite(_jellyfin('j1'), true);
      final emissions = <Set<String>>[];
      final sub = repo.favoritesStream.listen(emissions.add);
      await _settle();

      await repo.clearRemote();
      await _settle();
      await sub.cancel();

      expect(emissions.last, isNot(contains('jellyfin:j1')));
    });

    test('clearRemote is a no-op when there are no server favourites',
        () async {
      final repo = build(session: _session);
      await repo.setFavorite(_local('a'), true);

      await repo.clearRemote();

      expect(repo.isFavorite('file:///a.mp3'), isTrue);
      expect((await store.load()).localIds, <String>{'file:///a.mp3'});
    });
  });

  group('SyncedFavoritesRepository (Subsonic gateway)', () {
    late InMemoryFavoritesStore store;
    late FakeSubsonicClient client;

    setUp(() {
      store = InMemoryFavoritesStore();
      client = FakeSubsonicClient();
    });

    SyncedFavoritesRepository build({SubsonicSession? session}) {
      return SyncedFavoritesRepository(
        store: store,
        gateways: <RemoteFavoritesGateway>[
          SubsonicFavoritesGateway(client: client, session: () => session),
        ],
      );
    }

    test('hearting a Subsonic track stars it on the server and persists',
        () async {
      final repo = build(session: _subsonicSession);

      await repo.setFavorite(_subsonic('mf-1'), true);

      expect(repo.isFavorite('subsonic:mf-1'), isTrue);
      expect(client.starCalls,
          <({String songId, bool starred})>[(songId: 'mf-1', starred: true)]);
      expect((await store.load()).remoteIds, <String>{'subsonic:mf-1'});
    });

    test('unhearting a Subsonic track unstars it on the server', () async {
      final repo = build(session: _subsonicSession);
      await repo.setFavorite(_subsonic('mf-1'), true);

      await repo.setFavorite(_subsonic('mf-1'), false);

      expect(repo.isFavorite('subsonic:mf-1'), isFalse);
      expect(client.starCalls.last, (songId: 'mf-1', starred: false));
    });

    test('refreshFromRemote adopts the server starred set', () async {
      final repo = build(session: _subsonicSession);
      client.starredSongIds = <String>{'mf-7', 'mf-8'};

      final result = await repo.refreshFromRemote();

      expect(result.didSync, isTrue);
      expect(result.favoriteCount, 2);
      expect(repo.isFavorite('subsonic:mf-7'), isTrue);
      expect(repo.isFavorite('subsonic:mf-8'), isTrue);
    });

    test('a failed server star keeps the optimistic local favourite', () async {
      client.favoritesError = SubsonicException.notReachable();
      final repo = build(session: _subsonicSession);

      await repo.setFavorite(_subsonic('mf-1'), true);

      expect(repo.isFavorite('subsonic:mf-1'), isTrue);
      expect((await store.load()).remoteIds, <String>{'subsonic:mf-1'});
    });

    test('without a session, favourites stay purely local', () async {
      final repo = build(session: null);

      await repo.setFavorite(_subsonic('mf-1'), true);
      final result = await repo.refreshFromRemote();

      expect(result.outcome, RemoteSyncOutcome.notConfigured);
      expect(repo.isFavorite('subsonic:mf-1'), isTrue);
      expect(client.starCalls, isEmpty);
    });
  });

  group('SyncedFavoritesRepository (multi-provider)', () {
    late InMemoryFavoritesStore store;
    late FakeJellyfinClient jellyfin;
    late FakeSubsonicClient subsonic;

    setUp(() {
      store = InMemoryFavoritesStore();
      jellyfin = FakeJellyfinClient();
      subsonic = FakeSubsonicClient();
    });

    SyncedFavoritesRepository build() {
      return SyncedFavoritesRepository(
        store: store,
        gateways: <RemoteFavoritesGateway>[
          JellyfinFavoritesGateway(
            client: jellyfin,
            session: () => _session,
          ),
          SubsonicFavoritesGateway(
            client: subsonic,
            session: () => _subsonicSession,
          ),
        ],
      );
    }

    test('each heart pushes only to the provider that owns the track',
        () async {
      final repo = build();

      await repo.setFavorite(_jellyfin('j1'), true);
      await repo.setFavorite(_subsonic('mf-1'), true);

      expect(jellyfin.favoriteCalls,
          <({String itemId, bool favorite})>[(itemId: 'j1', favorite: true)]);
      expect(subsonic.starCalls,
          <({String songId, bool starred})>[(songId: 'mf-1', starred: true)]);
      expect(repo.isFavorite('jellyfin:j1'), isTrue);
      expect(repo.isFavorite('subsonic:mf-1'), isTrue);
    });

    test('refresh replaces each provider subset independently', () async {
      final repo = build();
      // Seed a local heart on each provider first.
      await repo.setFavorite(_jellyfin('j-old'), true);
      await repo.setFavorite(_subsonic('mf-old'), true);
      // Servers report different favourites (set on another client).
      jellyfin.favoriteIds = <String>{'j-new'};
      subsonic.starredSongIds = <String>{'mf-new'};

      await repo.refreshFromRemote();

      // Each scheme's subset is replaced by its own server's set, independently.
      expect(repo.isFavorite('jellyfin:j-new'), isTrue);
      expect(repo.isFavorite('subsonic:mf-new'), isTrue);
      expect(repo.isFavorite('jellyfin:j-old'), isFalse);
      expect(repo.isFavorite('subsonic:mf-old'), isFalse);
    });

    test('clearRemote(scheme) drops only that provider\'s favourites',
        () async {
      final repo = build();
      await repo.setFavorite(_jellyfin('j1'), true);
      await repo.setFavorite(_subsonic('mf-1'), true);
      await repo.setFavorite(_local('a'), true);

      await repo.clearRemote(providerScheme: 'subsonic:');

      // Only the Subsonic heart is dropped; Jellyfin and local survive.
      expect(repo.isFavorite('subsonic:mf-1'), isFalse);
      expect(repo.isFavorite('jellyfin:j1'), isTrue);
      expect(repo.isFavorite('file:///a.mp3'), isTrue);
    });
  });
}
