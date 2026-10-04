import 'dart:async';

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

  // A controllable gateway that lets a test vary push-failure and the server's
  // starred set independently — so the repository's retry/reconcile logic can be
  // exercised precisely (the shared client fake ties star and getStarred2 to one
  // error flag).
  group('SyncedFavoritesRepository (failed-write retry / non-revert)', () {
    late InMemoryFavoritesStore store;
    late _FakeFavoritesGateway gateway;

    setUp(() {
      store = InMemoryFavoritesStore();
      gateway = _FakeFavoritesGateway('subsonic:');
    });

    SyncedFavoritesRepository build() => SyncedFavoritesRepository(
          store: store,
          gateways: <RemoteFavoritesGateway>[gateway],
        );

    test('a failed star keeps the local heart and records a pending write',
        () async {
      gateway.pushFails = true;
      final repo = build();

      await repo.setFavorite(_subsonic('mf-1'), true);

      // Optimistic local heart stands; the server never got it, but it's queued.
      expect(repo.isFavorite('subsonic:mf-1'), isTrue);
      expect(repo.pendingRemoteWriteCount, 1);
      expect(gateway.serverUris, isEmpty);
    });

    test('a refresh never reverts an un-landed heart, and retries it',
        () async {
      gateway.pushFails = true;
      final repo = build();
      await repo.setFavorite(_subsonic('mf-1'), true);
      // The server's starred list still doesn't contain it (push failed).
      expect(gateway.serverUris, isEmpty);

      // First refresh: retry still fails, server list is empty — but the heart
      // must NOT be reverted (non-destructive: local intent wins until landed).
      await repo.refreshFromRemote();
      expect(repo.isFavorite('subsonic:mf-1'), isTrue);
      expect(repo.pendingRemoteWriteCount, 1);

      // The network recovers; the next refresh's retry lands the star, the
      // server now reports it, and the pending write clears.
      gateway.pushFails = false;
      await repo.refreshFromRemote();
      expect(gateway.serverUris, contains('subsonic:mf-1'));
      expect(repo.isFavorite('subsonic:mf-1'), isTrue);
      expect(repo.pendingRemoteWriteCount, 0);
      // The retry pushed the queued star.
      expect(
        gateway.pushes.where((p) => p.uri == 'subsonic:mf-1' && p.favorite),
        isNotEmpty,
      );
    });

    test('a heart that never reached the server survives a restart', () async {
      // Before, the pending write lived in memory only: after a restart the
      // first refresh adopted a starred list that never had it, and the heart
      // was gone for good.
      gateway.pushFails = true;
      await build().setFavorite(_subsonic('mf-1'), true);

      gateway.pushFails = false;
      final SyncedFavoritesRepository restarted = build();
      await restarted.refreshFromRemote();

      expect(restarted.isFavorite('subsonic:mf-1'), isTrue);
      expect(gateway.serverUris, contains('subsonic:mf-1'));
      expect(restarted.pendingRemoteWriteCount, 0);
      expect((await store.load()).pendingWrites, isEmpty);
    });

    test('an un-heart that never reached the server survives a restart',
        () async {
      gateway.serverUris.add('subsonic:mf-1');
      final SyncedFavoritesRepository first = build();
      await first.refreshFromRemote();
      expect(first.isFavorite('subsonic:mf-1'), isTrue);

      gateway.pushFails = true;
      await first.setFavorite(_subsonic('mf-1'), false);

      gateway.pushFails = false;
      final SyncedFavoritesRepository restarted = build();
      await restarted.refreshFromRemote();

      expect(restarted.isFavorite('subsonic:mf-1'), isFalse);
      expect(gateway.serverUris, isNot(contains('subsonic:mf-1')));
    });

    test('signing out drops its pending writes for good', () async {
      gateway.pushFails = true;
      final SyncedFavoritesRepository first = build();
      await first.setFavorite(_subsonic('mf-1'), true);
      await first.clearRemote(providerScheme: 'subsonic:');

      // Whoever signs in next did not make that heart.
      gateway.pushFails = false;
      final SyncedFavoritesRepository restarted = build();
      await restarted.refreshFromRemote();

      expect(restarted.pendingRemoteWriteCount, 0);
      expect(gateway.serverUris, isEmpty);
    });

    test('a queued heart made while disconnected pushes once connected',
        () async {
      gateway.connected = false;
      final repo = build();

      await repo.setFavorite(_subsonic('mf-2'), true);
      // Not connected: nothing pushed yet, but it's queued and kept locally.
      expect(gateway.pushes, isEmpty);
      expect(repo.isFavorite('subsonic:mf-2'), isTrue);
      expect(repo.pendingRemoteWriteCount, 1);

      gateway.connected = true;
      await repo.refreshFromRemote();
      expect(gateway.serverUris, contains('subsonic:mf-2'));
      expect(repo.pendingRemoteWriteCount, 0);
    });

    // Signing out keeps the server's songs in the library, so they can still
    // be hearted. Such a heart belongs to no account: whoever signs in next
    // (another person on a shared device, or another server) did not make it.
    test('a heart made after signing out is not sent to whoever signs in next',
        () async {
      final repo = build();
      gateway.connected = false;
      await repo.clearRemote(providerScheme: 'subsonic:');

      await repo.setFavorite(_subsonic('mf-2'), true);
      expect(repo.isFavorite('subsonic:mf-2'), isTrue);

      // Another account signs in; its server has nothing starred.
      gateway.connected = true;
      await repo.refreshFromRemote();

      expect(gateway.pushes, isEmpty);
      expect(gateway.serverUris, isEmpty);
      expect(repo.pendingRemoteWriteCount, 0);
      expect(repo.isFavorite('subsonic:mf-2'), isFalse);
    });

    test('a heart made once someone has signed in again is theirs', () async {
      final repo = build();
      gateway.connected = false;
      await repo.clearRemote(providerScheme: 'subsonic:');
      gateway.connected = true;

      await repo.setFavorite(_subsonic('mf-2'), true);

      expect(gateway.serverUris, contains('subsonic:mf-2'));
      expect(repo.pendingRemoteWriteCount, 0);
    });

    test('a successful star clears the pending write immediately', () async {
      final repo = build();
      await repo.setFavorite(_subsonic('mf-1'), true);
      expect(repo.pendingRemoteWriteCount, 0);
      expect(gateway.serverUris, contains('subsonic:mf-1'));
    });

    test('clearRemote drops queued writes for that provider', () async {
      gateway.pushFails = true;
      final repo = build();
      await repo.setFavorite(_subsonic('mf-1'), true);
      expect(repo.pendingRemoteWriteCount, 1);

      await repo.clearRemote(providerScheme: 'subsonic:');
      expect(repo.pendingRemoteWriteCount, 0);
    });
  });

  // A heart pushes to the server straight away, and the listener can tap again
  // (or sign out) before that push comes back. The newest tap is what the
  // server and the heart have to end on, whichever order the pushes land in.
  group('SyncedFavoritesRepository (pushes that come back out of order)', () {
    late InMemoryFavoritesStore store;
    late _FakeFavoritesGateway gateway;
    const String uri = 'subsonic:mf-1';

    setUp(() {
      store = InMemoryFavoritesStore();
      gateway = _FakeFavoritesGateway('subsonic:')..holdEachPush = true;
    });

    SyncedFavoritesRepository build() => SyncedFavoritesRepository(
          store: store,
          gateways: <RemoteFavoritesGateway>[gateway],
        );

    /// Hearts then un-hearts [uri], leaving both pushes on the wire.
    Future<({Future<void> heart, Future<void> unheart})> heartThenUnheart(
        SyncedFavoritesRepository repo) async {
      final Future<void> heart = repo.setFavorite(_subsonic('mf-1'), true);
      await _pumpUntil(() => gateway.heldPushes.isNotEmpty);
      final Future<void> unheart = repo.setFavorite(_subsonic('mf-1'), false);
      await _pumpUntil(() => gateway.heldPushes.length >= 2);
      return (heart: heart, unheart: unheart);
    }

    /// The listener's last word must survive the next refresh, on the server
    /// and in the heart.
    Future<void> expectEndsUnhearted(SyncedFavoritesRepository repo) async {
      gateway.holdEachPush = false;
      await repo.refreshFromRemote();
      expect(repo.isFavorite(uri), isFalse);
      expect(gateway.serverUris, isNot(contains(uri)));
      expect(repo.pendingRemoteWriteCount, 0);
    }

    test('a newer un-heart that failed is not cleared by the heart landing',
        () async {
      final repo = build();
      final pushes = await heartThenUnheart(repo);

      gateway.heldPushes[1].fail();
      await pushes.unheart;
      gateway.heldPushes[0].land();
      await pushes.heart;

      expect(repo.isFavorite(uri), isFalse);
      expect(repo.pendingRemoteWriteCount, 1);
      await expectEndsUnhearted(repo);
    });

    test('an older heart failing late does not queue it over the un-heart',
        () async {
      final repo = build();
      final pushes = await heartThenUnheart(repo);

      gateway.heldPushes[1].land();
      await pushes.unheart;
      gateway.heldPushes[0].fail();
      await pushes.heart;

      expect(repo.isFavorite(uri), isFalse);
      await expectEndsUnhearted(repo);
    });

    test('an older heart landing after the un-heart is put right', () async {
      // Both reached the server, the un-heart first: the server is left
      // starred. The un-heart has to be sent again, not the heart adopted.
      final repo = build();
      final pushes = await heartThenUnheart(repo);

      gateway.heldPushes[1].land();
      await pushes.unheart;
      gateway.heldPushes[0].land();
      await pushes.heart;
      expect(gateway.serverUris, contains(uri));

      expect(repo.isFavorite(uri), isFalse);
      await expectEndsUnhearted(repo);
    });

    // A refresh sends every write still pending again: one whose push failed,
    // and one whose push is still on the wire. That copy is a push like any
    // other, and a newer tap's push can reach the server before it.
    test(
        'a failed heart the refresh sends again, landing after the un-heart, '
        'is put right', () async {
      final repo = build();
      final Future<void> heart = repo.setFavorite(_subsonic('mf-1'), true);
      await _pumpUntil(() => gateway.heldPushes.isNotEmpty);
      gateway.heldPushes[0].fail();
      await heart;

      final Future<FavoritesSyncResult> refresh = repo.refreshFromRemote();
      await _pumpUntil(() => gateway.heldPushes.length >= 2);
      final Future<void> unheart = repo.setFavorite(_subsonic('mf-1'), false);
      await _pumpUntil(() => gateway.heldPushes.length >= 3);

      gateway.heldPushes[2].land();
      await unheart;
      gateway.heldPushes[1].land();
      await refresh;

      expect(repo.isFavorite(uri), isFalse);
      await expectEndsUnhearted(repo);
    });

    test(
        'a heart the refresh sends again while its own push is out is put '
        'right when it lands last', () async {
      final repo = build();
      final Future<void> heart = repo.setFavorite(_subsonic('mf-1'), true);
      await _pumpUntil(() => gateway.heldPushes.isNotEmpty);
      final Future<FavoritesSyncResult> refresh = repo.refreshFromRemote();
      await _pumpUntil(() => gateway.heldPushes.length >= 2);
      final Future<void> unheart = repo.setFavorite(_subsonic('mf-1'), false);
      await _pumpUntil(() => gateway.heldPushes.length >= 3);

      gateway.heldPushes[0].land();
      await heart;
      gateway.heldPushes[2].land();
      await unheart;
      gateway.heldPushes[1].land();
      await refresh;

      expect(repo.isFavorite(uri), isFalse);
      await expectEndsUnhearted(repo);
    });

    test('a push that fails after sign-out is not queued for the next account',
        () async {
      final repo = build();
      final Future<void> heart = repo.setFavorite(_subsonic('mf-1'), true);
      await _pumpUntil(() => gateway.heldPushes.isNotEmpty);

      await repo.clearRemote(providerScheme: 'subsonic:');
      gateway.heldPushes[0].fail();
      await heart;

      expect(repo.pendingRemoteWriteCount, 0);
      expect(repo.isFavorite(uri), isFalse);
    });

    test('controls: in order, a single tap lands and leaves nothing pending',
        () async {
      final repo = build();
      final pushes = await heartThenUnheart(repo);

      gateway.heldPushes[0].land();
      await pushes.heart;
      gateway.heldPushes[1].land();
      await pushes.unheart;

      expect(repo.pendingRemoteWriteCount, 0);
      expect(gateway.serverUris, isNot(contains(uri)));
      await expectEndsUnhearted(repo);
    });
  });

  // A refresh waits on the network, and the user keeps hearting (or signs out)
  // meanwhile. The server's answer must be adopted into the favourites as they
  // are when it lands, never written over them.
  group('SyncedFavoritesRepository (changes during an in-flight refresh)', () {
    late InMemoryFavoritesStore store;
    late _FakeFavoritesGateway gateway;

    setUp(() {
      store = InMemoryFavoritesStore();
      gateway = _FakeFavoritesGateway('subsonic:');
    });

    SyncedFavoritesRepository build([List<RemoteFavoritesGateway>? gateways]) =>
        SyncedFavoritesRepository(
          store: store,
          gateways: gateways ?? <RemoteFavoritesGateway>[gateway],
        );

    /// Runs [repo]'s refresh with [gateway]'s fetch held until [during] has
    /// finished, the way a slow server leaves the user time to act first.
    Future<FavoritesSyncResult> refreshAround(
      SyncedFavoritesRepository repo,
      Future<void> Function() during,
    ) async {
      gateway.holdFetch();
      final Future<FavoritesSyncResult> refresh = repo.refreshFromRemote();
      await gateway.fetchStarted;
      await during();
      gateway.releaseFetch();
      return refresh;
    }

    test('a heart made during a refresh survives it', () async {
      final repo = build();
      gateway.serverUris.add('subsonic:mf-old');

      await refreshAround(
          repo, () => repo.setFavorite(_subsonic('mf-1'), true));

      expect(repo.isFavorite('subsonic:mf-1'), isTrue);
      expect(repo.isFavorite('subsonic:mf-old'), isTrue);
      expect(
        (await store.load()).remoteIds,
        <String>{'subsonic:mf-1', 'subsonic:mf-old'},
      );
    });

    test('an un-heart made during a refresh stays un-hearted', () async {
      final repo = build();
      await repo.setFavorite(_subsonic('mf-1'), true);

      // The held fetch answered while mf-1 was still starred on the server.
      await refreshAround(
        repo,
        () => repo.setFavorite(_subsonic('mf-1'), false),
      );

      expect(repo.isFavorite('subsonic:mf-1'), isFalse);
      expect((await store.load()).remoteIds, isEmpty);
    });

    test('signing out during a refresh that then fails keeps it cleared',
        () async {
      final repo = build();
      await repo.setFavorite(_subsonic('mf-1'), true);
      gateway.fetchFails = true;

      final FavoritesSyncResult result = await refreshAround(
        repo,
        () => repo.clearRemote(providerScheme: 'subsonic:'),
      );

      expect(result.didFail, isTrue);
      expect(repo.isFavorite('subsonic:mf-1'), isFalse);
      expect((await store.load()).remoteIds, isEmpty);
    });

    test('signing out during a refresh that then succeeds keeps it cleared',
        () async {
      final repo = build();
      await repo.setFavorite(_subsonic('mf-1'), true);
      gateway.serverUris.add('subsonic:mf-2');

      // The gateway stays "connected": only the clear itself says the answer
      // belongs to an account that is gone.
      await refreshAround(
        repo,
        () => repo.clearRemote(providerScheme: 'subsonic:'),
      );

      expect(repo.isFavorite('subsonic:mf-1'), isFalse);
      expect(repo.isFavorite('subsonic:mf-2'), isFalse);
      expect((await store.load()).remoteIds, isEmpty);
    });

    test('signing out of one provider during a refresh still adopts the other',
        () async {
      final _FakeFavoritesGateway jellyfin = _FakeFavoritesGateway('jellyfin:')
        ..serverUris.add('jellyfin:j-1');
      final repo = build(<RemoteFavoritesGateway>[jellyfin, gateway]);
      gateway.serverUris.add('subsonic:mf-1');

      await refreshAround(
        repo,
        () => repo.clearRemote(providerScheme: 'jellyfin:'),
      );

      expect(repo.isFavorite('jellyfin:j-1'), isFalse);
      expect(repo.isFavorite('subsonic:mf-1'), isTrue);
      expect((await store.load()).remoteIds, <String>{'subsonic:mf-1'});
    });

    test('signing out while a refresh retries queued hearts does not throw',
        () async {
      gateway.pushFails = true;
      final repo = build();
      await repo.setFavorite(_subsonic('mf-1'), true);
      await repo.setFavorite(_subsonic('mf-2'), true);
      expect(repo.pendingRemoteWriteCount, 2);

      final Completer<void> slow = Completer<void>();
      gateway.pushGate = slow;
      final Future<FavoritesSyncResult> refresh = repo.refreshFromRemote();
      await pumpEventQueue(); // the retry of mf-1 is on the wire
      await repo.clearRemote(providerScheme: 'subsonic:');
      gateway.pushGate = null;
      slow.complete();
      await refresh;

      expect(repo.isFavorite('subsonic:mf-1'), isFalse);
      expect(repo.isFavorite('subsonic:mf-2'), isFalse);
      expect(repo.pendingRemoteWriteCount, 0);
      // mf-2's queued write was dropped by the sign-out, so it is not retried.
      expect(
        gateway.pushes.where((p) => p.uri == 'subsonic:mf-2'),
        hasLength(1),
      );
    });

    test('a toggle made while its retry is on the wire keeps the newer intent',
        () async {
      gateway.pushFails = true;
      final repo = build();
      await repo.setFavorite(_subsonic('mf-1'), true); // queued: heart

      // The refresh retries the heart, slowly; it will land on the server.
      gateway.pushFails = false;
      final Completer<void> slow = Completer<void>();
      gateway.pushGate = slow;
      final Future<FavoritesSyncResult> refresh = repo.refreshFromRemote();
      await pumpEventQueue();
      // Meanwhile the user un-hearts it, and that push fails.
      gateway.pushGate = null;
      gateway.pushFails = true;
      await repo.setFavorite(_subsonic('mf-1'), false); // queued: un-heart
      gateway.pushFails = false;
      slow.complete();
      await refresh;

      expect(repo.isFavorite('subsonic:mf-1'), isFalse);
      expect(repo.pendingRemoteWriteCount, 1);

      // The next refresh lands the un-heart instead of adopting the old star.
      await repo.refreshFromRemote();
      expect(repo.isFavorite('subsonic:mf-1'), isFalse);
      expect(gateway.serverUris, isNot(contains('subsonic:mf-1')));
      expect(repo.pendingRemoteWriteCount, 0);
    });
  });
}

/// A minimal [RemoteFavoritesGateway] whose push-failure and server starred set
/// are independently controllable, for the repository's retry/reconcile tests.
class _FakeFavoritesGateway implements RemoteFavoritesGateway {
  _FakeFavoritesGateway(this._scheme);

  final String _scheme;
  bool connected = true;
  bool pushFails = false;
  final Set<String> serverUris = <String>{};
  final List<({String uri, bool favorite})> pushes =
      <({String uri, bool favorite})>[];

  @override
  String get uriScheme => _scheme;

  @override
  bool get isConnected => connected;

  /// Makes the next fetches throw (after any hold) like an unreachable server.
  bool fetchFails = false;

  /// While set, a push waits on it before landing, like a slow network.
  Completer<void>? pushGate;

  Completer<void>? _fetchGate;
  Completer<void> _fetchStarted = Completer<void>();

  /// Holds every fetch from now until [releaseFetch].
  void holdFetch() {
    _fetchGate = Completer<void>();
    _fetchStarted = Completer<void>();
  }

  /// Completes once a fetch has read the server set (and, if held, is waiting
  /// for [releaseFetch]).
  Future<void> get fetchStarted => _fetchStarted.future;

  void releaseFetch() {
    _fetchGate?.complete();
    _fetchGate = null;
  }

  // The starred set is read when the fetch starts, like a server that
  // answered before anything done during the hold reached it.
  @override
  Future<Set<String>> fetchFavoriteUris() async {
    final Set<String> answer = <String>{...serverUris};
    final Completer<void>? gate = _fetchGate;
    if (!_fetchStarted.isCompleted) _fetchStarted.complete();
    if (gate != null) await gate.future;
    if (fetchFails) throw const RemoteSyncException('unreachable');
    return answer;
  }

  /// While set, every push waits on its own [_HeldPush] in [heldPushes], so a
  /// test picks the order pushes land in, and which of them fail.
  bool holdEachPush = false;
  final List<_HeldPush> heldPushes = <_HeldPush>[];

  @override
  Future<void> pushFavorite(String trackUri, bool favorite) async {
    pushes.add((uri: trackUri, favorite: favorite));
    if (holdEachPush) {
      final _HeldPush held = _HeldPush();
      heldPushes.add(held);
      await held._gate.future;
      if (held._fails) throw const RemoteSyncException('unreachable');
      if (favorite) {
        serverUris.add(trackUri);
      } else {
        serverUris.remove(trackUri);
      }
      return;
    }
    final Completer<void>? gate = pushGate;
    if (gate != null) await gate.future;
    if (pushFails) throw const RemoteSyncException('unreachable');
    if (favorite) {
      serverUris.add(trackUri);
    } else {
      serverUris.remove(trackUri);
    }
  }
}

/// One push held by [_FakeFavoritesGateway.holdEachPush].
class _HeldPush {
  final Completer<void> _gate = Completer<void>();
  bool _fails = false;

  /// Lets it reach the server.
  void land() => _gate.complete();

  /// Fails it, like a dropped connection.
  void fail() {
    _fails = true;
    _gate.complete();
  }
}

/// Pumps event-loop turns until [condition] holds, or a bounded number pass.
Future<void> _pumpUntil(bool Function() condition) async {
  for (int i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
