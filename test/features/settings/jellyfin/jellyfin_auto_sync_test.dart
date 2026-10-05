import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/download_progress.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/repositories/music_library_repository.dart';
import 'package:linthra/core/repositories/remote_catalog_owner_store.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_account_fingerprint.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/favorites_repository_provider.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_auto_sync_store.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_session_store.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_remote_catalog_owner_store.dart';
import 'package:linthra/data/repositories/jellyfin_auto_sync_store_provider.dart';
import 'package:linthra/data/repositories/jellyfin_session_store_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/data/repositories/remote_catalog_owner_store_provider.dart';
import 'package:linthra/features/player/favorites_providers.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_providers.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_state.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_sync_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_sync_state.dart';

import '../../../core/sources/jellyfin/fake_jellyfin_client.dart';
import '../../player/fake_playback_controller.dart';
import 'fake_jellyfin_authenticator.dart';

JellyfinSession _sessionFor({
  String baseUrl = 'https://music.example.com',
  String userId = 'user-1',
  String userName = 'alice',
}) =>
    JellyfinSession(
      baseUrl: baseUrl,
      userId: userId,
      accessToken: 'secret-token-value',
      deviceId: 'device-1',
      userName: userName,
      serverName: 'Home',
    );

JellyfinItemDto _audio(String id) => JellyfinItemDto(
      id: id,
      name: 'Track $id',
      album: 'Album',
      artists: const <String>['Artist'],
      runTimeTicks: 1000000,
      indexNumber: 1,
    );

/// A recording [MusicLibraryRepository] that counts upserts and remembers the
/// last one, so a test can prove auto-sync went down the same upsert path as a
/// manual sync (and how many times it ran).
class _RecordingRepository implements MusicLibraryRepository {
  int upsertCount = 0;
  String? lastSourceId;
  List<Track> lastTracks = const <Track>[];

  @override
  Future<void> upsertCatalog({
    required String sourceId,
    required List<Track> tracks,
    required List<Album> albums,
    required List<Artist> artists,
  }) async {
    upsertCount++;
    lastSourceId = sourceId;
    lastTracks = tracks;
  }

  @override
  Future<List<Track>> getAllTracks() async => lastTracks;

  @override
  Future<List<Album>> getAllAlbums() async => const <Album>[];

  @override
  Future<List<Artist>> getAllArtists() async => const <Artist>[];

  @override
  Future<Track?> getTrackByUri(String uri) async => null;

  @override
  Future<void> removeTracks(List<String> trackIds) async {}
}

/// Counts download requests so a test can prove the metadata sync never kicks
/// off a download/cache fetch on its own.
class _SpyDownloadRepository implements DownloadRepository {
  int requestCount = 0;

  @override
  Future<DownloadRequestOutcome> requestDownload(Track track) async {
    requestCount++;
    return DownloadRequestOutcome.started;
  }

  @override
  Stream<Map<String, DownloadStatus>> get statusStream =>
      const Stream<Map<String, DownloadStatus>>.empty();

  @override
  Stream<Map<String, DownloadProgress>> get progressStream =>
      const Stream<Map<String, DownloadProgress>>.empty();

  @override
  Future<DownloadStatus> statusFor(String trackId) async =>
      DownloadStatus.notDownloaded;

  @override
  Future<void> removeDownload(Track track) async {}

  @override
  Future<List<String>> downloadedTrackKeys() async => const <String>[];

  @override
  Future<void> retryHeldDownloads() async {}
}

ProviderContainer _container({
  required FakeJellyfinAuthenticator authenticator,
  required MusicLibraryRepository repository,
  InMemoryJellyfinAutoSyncStore? autoSyncStore,
  RemoteCatalogOwnerStore? owners,
  JellyfinSession? restoredSession,
  FakeJellyfinClient? client,
  _SpyDownloadRepository? downloads,
  bool serverPlaylistsAndFavorites = false,
  List<Override> overrides = const <Override>[],
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      ...overrides,
      jellyfinAuthenticatorProvider.overrideWithValue(authenticator),
      jellyfinSessionStoreProvider.overrideWithValue(
        InMemoryJellyfinSessionStore(initialSession: restoredSession),
      ),
      jellyfinClientProvider.overrideWithValue(
        client ??
            FakeJellyfinClient(
              itemsByKind: <JellyfinItemKind, List<JellyfinItemDto>>{
                JellyfinItemKind.audio: <JellyfinItemDto>[
                  _audio('a'),
                  _audio('b'),
                ],
              },
            ),
      ),
      jellyfinAutoSyncStoreProvider
          .overrideWithValue(autoSyncStore ?? InMemoryJellyfinAutoSyncStore()),
      if (owners != null)
        remoteCatalogOwnerStoreProvider.overrideWithValue(owners),
      musicLibraryRepositoryProvider.overrideWithValue(repository),
      if (downloads != null)
        downloadRepositoryProvider.overrideWithValue(downloads),
      // Production wiring for server playlists and favourites.
      if (serverPlaylistsAndFavorites) ...<Override>[
        remotePlaylistSyncOverride,
        remoteFavoritesSyncOverride,
      ],
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Lets the controller's async load settle.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

/// Drains the fire-and-forget auto-sync started by sign-in to completion.
Future<void> _drainAutoSync() => pumpEventQueue(times: 50);

Future<bool> _signIn(
  ProviderContainer container, {
  String url = 'music.example.com',
  String username = 'alice',
}) =>
    container.read(jellyfinSettingsControllerProvider.notifier).signIn(
          url: url,
          username: username,
          password: 'pw',
        );

void main() {
  group('Jellyfin auto-sync on connect', () {
    test('a successful sign-in triggers exactly one auto-sync', () async {
      final repo = _RecordingRepository();
      final store = InMemoryJellyfinAutoSyncStore();
      final container = _container(
        authenticator: FakeJellyfinAuthenticator(session: _sessionFor()),
        repository: repo,
        autoSyncStore: store,
      );
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      expect(await _signIn(container), isTrue);
      await _drainAutoSync();

      // One sync ran down the normal upsert path…
      expect(repo.upsertCount, 1);
      expect(repo.lastSourceId, 'jellyfin');
      expect(repo.lastTracks, hasLength(2));
      // …and finished as a success the UI can show.
      expect(
        container.read(jellyfinSyncControllerProvider).status,
        JellyfinSyncStatus.success,
      );
      // The account is now remembered so it won't auto-sync again on its own.
      expect(await store.read(), jellyfinAccountFingerprint(_sessionFor()));
    });

    test('a failed sign-in does not trigger a sync', () async {
      final repo = _RecordingRepository();
      final store = InMemoryJellyfinAutoSyncStore();
      final container = _container(
        authenticator: FakeJellyfinAuthenticator(
          signInError: JellyfinException.unauthorized(),
        ),
        repository: repo,
        autoSyncStore: store,
      );
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      expect(await _signIn(container), isFalse);
      await _drainAutoSync();

      expect(repo.upsertCount, 0);
      expect(
        container.read(jellyfinSyncControllerProvider).status,
        JellyfinSyncStatus.idle,
      );
      expect(await store.read(), isNull);
    });

    test('reconnecting the same account does not auto-sync again', () async {
      final repo = _RecordingRepository();
      // The store already remembers this exact account from a prior run.
      final store = InMemoryJellyfinAutoSyncStore(
          jellyfinAccountFingerprint(_sessionFor()));
      final container = _container(
        authenticator: FakeJellyfinAuthenticator(session: _sessionFor()),
        repository: repo,
        autoSyncStore: store,
      );
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      expect(await _signIn(container), isTrue);
      await _drainAutoSync();

      // Connected, but no unsolicited full re-sync — the manual button remains.
      expect(repo.upsertCount, 0);
      expect(
        container.read(jellyfinSyncControllerProvider).status,
        JellyfinSyncStatus.idle,
      );
    });

    test(
        'signing back in to the same account brings back the playlists and '
        'favourites signing out cleared', () async {
      // What the app asks for when a session expires: sign out, then sign in
      // again.
      final client = FakeJellyfinClient(
        itemsByKind: <JellyfinItemKind, List<JellyfinItemDto>>{
          JellyfinItemKind.audio: <JellyfinItemDto>[_audio('a'), _audio('b')],
        },
      )
        ..favoriteIds = <String>{'b'}
        ..playlists = const <JellyfinPlaylistDto>[
          JellyfinPlaylistDto(id: 'srv-1', name: 'Road Trip'),
        ];
      client.playlistEntries['srv-1'] = const <JellyfinPlaylistEntry>[
        JellyfinPlaylistEntry(itemId: 'a', playlistItemId: 'e-1'),
      ];
      final repo = _RecordingRepository();
      final container = _container(
        authenticator: FakeJellyfinAuthenticator(session: _sessionFor()),
        repository: repo,
        client: client,
        serverPlaylistsAndFavorites: true,
      );
      Future<int> serverPlaylists() async => <Playlist>[
            for (final Playlist p in await container
                .read(playlistRepositoryProvider)
                .getAllPlaylists())
              if (p.source == PlaylistSource.jellyfin) p,
          ].length;
      bool hearted() =>
          container.read(favoritesRepositoryProvider).isFavorite('jellyfin:b');
      container.read(jellyfinSettingsControllerProvider);
      await _settle();
      expect(await _signIn(container), isTrue);
      await _drainAutoSync();
      expect(await serverPlaylists(), 1);
      expect(hearted(), isTrue);

      await container.read(jellyfinSettingsControllerProvider.notifier).clear();
      expect(await serverPlaylists(), 0);
      expect(hearted(), isFalse);

      expect(await _signIn(container), isTrue);
      await _drainAutoSync();

      expect(await serverPlaylists(), 1);
      expect(hearted(), isTrue);
      // Still no second full library sync.
      expect(repo.upsertCount, 1);
    });

    test('changing server/account allows a new initial auto-sync', () async {
      final repo = _RecordingRepository();
      final store = InMemoryJellyfinAutoSyncStore();
      final auth = FakeJellyfinAuthenticator(session: _sessionFor());
      final container = _container(
        authenticator: auth,
        repository: repo,
        autoSyncStore: store,
      );
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      // First account.
      await _signIn(container);
      await _drainAutoSync();
      expect(repo.upsertCount, 1);

      // Sign out, then sign in to a *different* server + user.
      await container.read(jellyfinSettingsControllerProvider.notifier).clear();
      auth.session = _sessionFor(
        baseUrl: 'https://other.example.com',
        userId: 'user-2',
        userName: 'bob',
      );
      await _signIn(container, url: 'other.example.com', username: 'bob');
      await _drainAutoSync();

      // The new account is a fresh connection, so it auto-syncs once more,
      // after the first account's tracks were cleared (#741).
      expect(repo.upsertCount, 3);
      expect(repo.lastTracks, hasLength(2));
      expect(
        await store.read(),
        jellyfinAccountFingerprint(
          _sessionFor(baseUrl: 'https://other.example.com', userId: 'user-2'),
        ),
      );
    });

    test('signing in to another account mid-sync still syncs it', () async {
      // Before, the second account's auto-sync found the first one still
      // running and returned; the first then dropped its stale result, and
      // the new account never synced in that session.
      final repo = _RecordingRepository();
      final store = InMemoryJellyfinAutoSyncStore();
      final auth = FakeJellyfinAuthenticator(session: _sessionFor());
      final client = FakeJellyfinClient(
        itemsByKind: <JellyfinItemKind, List<JellyfinItemDto>>{
          JellyfinItemKind.audio: <JellyfinItemDto>[_audio('a'), _audio('b')],
        },
      )..itemsGate = Completer<void>();
      final container = _container(
        authenticator: auth,
        repository: repo,
        autoSyncStore: store,
        client: client,
      );
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      // Alice's auto-sync parks on the library fetch.
      await _signIn(container);
      await _settle();
      expect(container.read(jellyfinSyncControllerProvider).isSyncing, isTrue);

      await container.read(jellyfinSettingsControllerProvider.notifier).clear();
      final JellyfinSession bob = _sessionFor(
        baseUrl: 'https://other.example.com',
        userId: 'user-2',
        userName: 'bob',
      );
      auth.session = bob;
      await _signIn(container, url: 'other.example.com', username: 'bob');

      client.itemsGate!.complete();
      await _drainAutoSync();

      // Alice's tracks are cleared at Bob's sign-in (#741); after that only
      // Bob's library is written, never Alice's stale result.
      expect(repo.upsertCount, 2, reason: "only Bob's library is written");
      expect(await store.read(), jellyfinAccountFingerprint(bob));
      expect(
        container.read(jellyfinSyncControllerProvider).status,
        JellyfinSyncStatus.success,
      );
    });

    test('a manual Sync while the next account waits still records it',
        () async {
      // Signing out leaves the card idle, so Sync can be pressed while Bob's
      // first auto-sync waits behind Alice's. Before, that press replaced
      // Bob's fingerprint, his sync went unrecorded, and he would auto-sync
      // his whole library again on his next sign-in.
      final store = InMemoryJellyfinAutoSyncStore();
      final auth = FakeJellyfinAuthenticator(session: _sessionFor());
      final client = FakeJellyfinClient(
        itemsByKind: <JellyfinItemKind, List<JellyfinItemDto>>{
          JellyfinItemKind.audio: <JellyfinItemDto>[_audio('a')],
        },
      )..itemsGate = Completer<void>();
      final container = _container(
        authenticator: auth,
        repository: _RecordingRepository(),
        autoSyncStore: store,
        client: client,
      );
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      await _signIn(container);
      await _settle();
      await container.read(jellyfinSettingsControllerProvider.notifier).clear();
      final JellyfinSession bob = _sessionFor(
        baseUrl: 'https://other.example.com',
        userId: 'user-2',
        userName: 'bob',
      );
      auth.session = bob;
      await _signIn(container, url: 'other.example.com', username: 'bob');
      await pumpEventQueue(times: 10);

      await container.read(jellyfinSyncControllerProvider.notifier).sync();
      client.itemsGate!.complete();
      await _drainAutoSync();

      expect(await store.read(), jellyfinAccountFingerprint(bob));
    });

    test("a queued re-run never records another account's first sync",
        () async {
      // Bob's auto-sync waits behind Alice's, then Carol signs in. Carol was
      // synced before, so she queues nothing, and the re-run syncs her. It
      // must not mark Bob as synced: his library has never been pulled.
      final JellyfinSession bob = _sessionFor(
        baseUrl: 'https://other.example.com',
        userId: 'user-2',
        userName: 'bob',
      );
      final JellyfinSession carol = _sessionFor(
        baseUrl: 'https://third.example.com',
        userId: 'user-3',
        userName: 'carol',
      );
      final store =
          InMemoryJellyfinAutoSyncStore(jellyfinAccountFingerprint(carol));
      final auth = FakeJellyfinAuthenticator(session: _sessionFor());
      final client = FakeJellyfinClient(
        itemsByKind: <JellyfinItemKind, List<JellyfinItemDto>>{
          JellyfinItemKind.audio: <JellyfinItemDto>[_audio('a')],
        },
      )..itemsGate = Completer<void>();
      final container = _container(
        authenticator: auth,
        repository: _RecordingRepository(),
        autoSyncStore: store,
        client: client,
      );
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      await _signIn(container);
      await _settle();
      final JellyfinSettingsController settings =
          container.read(jellyfinSettingsControllerProvider.notifier);
      await settings.clear();
      auth.session = bob;
      await _signIn(container, url: 'other.example.com', username: 'bob');
      await pumpEventQueue(times: 10);
      await settings.clear();
      auth.session = carol;
      await _signIn(container, url: 'third.example.com', username: 'carol');
      await pumpEventQueue(times: 10);

      client.itemsGate!.complete();
      await _drainAutoSync();

      expect(await store.read(), jellyfinAccountFingerprint(carol));
    });

    test('manual sync still works after the auto-sync', () async {
      final repo = _RecordingRepository();
      final container = _container(
        authenticator: FakeJellyfinAuthenticator(session: _sessionFor()),
        repository: repo,
      );
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      await _signIn(container);
      await _drainAutoSync();
      expect(repo.upsertCount, 1);

      // The user can still pull a refresh on demand.
      await container.read(jellyfinSyncControllerProvider.notifier).sync();
      expect(repo.upsertCount, 2);
      expect(
        container.read(jellyfinSyncControllerProvider).status,
        JellyfinSyncStatus.success,
      );
    });

    test('auto-sync uses the same path as a manual sync', () async {
      // Drive the manual sync and the auto-sync over identical inputs and prove
      // they store the same catalog under the same source id.
      final manualRepo = _RecordingRepository();
      final manual = _container(
        authenticator: FakeJellyfinAuthenticator(session: _sessionFor()),
        repository: manualRepo,
        // A store that already knows the account, so sign-in won't auto-sync —
        // leaving the manual call as the only sync.
        autoSyncStore: InMemoryJellyfinAutoSyncStore(
          jellyfinAccountFingerprint(_sessionFor()),
        ),
      );
      manual.read(jellyfinSettingsControllerProvider);
      await _settle();
      await _signIn(manual);
      await _drainAutoSync();
      expect(manualRepo.upsertCount, 0); // confirmed: auto-sync was skipped
      await manual.read(jellyfinSyncControllerProvider.notifier).sync();

      final autoRepo = _RecordingRepository();
      final auto = _container(
        authenticator: FakeJellyfinAuthenticator(session: _sessionFor()),
        repository: autoRepo,
      );
      auto.read(jellyfinSettingsControllerProvider);
      await _settle();
      await _signIn(auto);
      await _drainAutoSync();

      expect(autoRepo.lastSourceId, manualRepo.lastSourceId);
      expect(
        autoRepo.lastTracks.map((t) => t.id),
        manualRepo.lastTracks.map((t) => t.id),
      );
    });

    test('a sync failure after sign-in surfaces a friendly retry state',
        () async {
      final repo = _RecordingRepository();
      final store = InMemoryJellyfinAutoSyncStore();
      final container = _container(
        authenticator: FakeJellyfinAuthenticator(session: _sessionFor()),
        repository: repo,
        autoSyncStore: store,
        // The catalog fetch fails once connected, but the server itself stays
        // reachable (the fake's verifySession succeeds), so this is a
        // library-sync failure — not "server unreachable".
        client:
            FakeJellyfinClient(itemsError: JellyfinException.notReachable()),
      );
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      expect(await _signIn(container), isTrue);
      await _drainAutoSync();

      // Still connected, sync errored with a friendly, secret-free message that
      // correctly says the connection is fine and the library was kept — NOT
      // the misleading "couldn't reach your server".
      expect(
        container.read(jellyfinSettingsControllerProvider).phase,
        JellyfinConnectionPhase.connected,
      );
      final syncState = container.read(jellyfinSyncControllerProvider);
      expect(syncState.status, JellyfinSyncStatus.error);
      expect(
        syncState.failureReason,
        JellyfinSyncFailureReason.librarySyncFailed,
      );
      expect(syncState.message, isNot(contains("Couldn't reach")));
      expect(syncState.message, contains('still here'));
      expect(syncState.message, isNot(contains('secret-token-value')));
      // The account is NOT recorded, so the next fresh connection retries.
      expect(await store.read(), isNull);
    });

    test('the auto-sync starts no downloads or cache fetches', () async {
      final repo = _RecordingRepository();
      final downloads = _SpyDownloadRepository();
      final container = _container(
        authenticator: FakeJellyfinAuthenticator(session: _sessionFor()),
        repository: repo,
        downloads: downloads,
      );
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      await _signIn(container);
      await _drainAutoSync();

      expect(repo.upsertCount, 1); // metadata synced…
      expect(downloads.requestCount, 0); // …but nothing was downloaded.
    });

    test('repeated provider rebuilds do not resync', () async {
      final repo = _RecordingRepository();
      final container = _container(
        authenticator: FakeJellyfinAuthenticator(session: _sessionFor()),
        repository: repo,
      );
      container.read(jellyfinSettingsControllerProvider);
      await _settle();
      await _signIn(container);
      await _drainAutoSync();
      expect(repo.upsertCount, 1);

      // The sync path reads the live source through jellyfinMusicSourceProvider.
      // Rebuilding it repeatedly (as a connection-state change or a widget
      // rebuild would) re-mints the source but, since auto-sync lives in
      // sign-in and not in any build(), must never kick off another sync.
      for (int i = 0; i < 5; i++) {
        container.invalidate(jellyfinMusicSourceProvider);
        container.read(jellyfinMusicSourceProvider);
        container.read(jellyfinSyncControllerProvider);
        await _drainAutoSync();
      }

      expect(repo.upsertCount, 1);
    });
  });

  group('switching account (#741)', () {
    final JellyfinSession alice = _sessionFor();
    final JellyfinSession bob = _sessionFor(
      baseUrl: 'https://other.example.com',
      userId: 'user-2',
      userName: 'bob',
    );

    late InMemoryMusicLibraryRepository catalog;
    late InMemoryJellyfinAutoSyncStore autoSync;
    late InMemoryRemoteCatalogOwnerStore owners;
    late FakeJellyfinAuthenticator auth;
    late FakeJellyfinClient client;

    setUp(() {
      catalog = InMemoryMusicLibraryRepository();
      autoSync = InMemoryJellyfinAutoSyncStore();
      owners = InMemoryRemoteCatalogOwnerStore();
      auth = FakeJellyfinAuthenticator(session: alice);
      client = FakeJellyfinClient(
        itemsByKind: <JellyfinItemKind, List<JellyfinItemDto>>{
          JellyfinItemKind.audio: <JellyfinItemDto>[_audio('a'), _audio('b')],
        },
      );
    });

    ProviderContainer app({
      JellyfinSession? restoredSession,
      List<Override> overrides = const <Override>[],
    }) {
      final ProviderContainer container = _container(
        authenticator: auth,
        repository: catalog,
        autoSyncStore: autoSync,
        owners: owners,
        restoredSession: restoredSession,
        client: client,
        overrides: overrides,
      );
      container.read(jellyfinSettingsControllerProvider);
      return container;
    }

    Future<List<String>> jellyfinUris() async => <String>[
          for (final Track t in await catalog.getTracksForSource('jellyfin'))
            t.uri,
        ];

    Future<void> signInAs(ProviderContainer c, JellyfinSession session) async {
      auth.session = session;
      expect(
        await _signIn(
          c,
          url: Uri.parse(session.baseUrl).host,
          username: session.userName!,
        ),
        isTrue,
      );
      await _drainAutoSync();
    }

    Future<void> signOut(ProviderContainer c) =>
        c.read(jellyfinSettingsControllerProvider.notifier).clear();

    /// Alice signed in, synced, and signed out: the library keeps her tracks.
    Future<ProviderContainer> aliceSyncedAndLeft({
      List<Override> overrides = const <Override>[],
    }) async {
      final ProviderContainer c = app(overrides: overrides);
      await _settle();
      await signInAs(c, alice);
      expect(await jellyfinUris(), hasLength(2));
      await signOut(c);
      expect(await jellyfinUris(), hasLength(2), reason: 'kept on sign-out');
      return c;
    }

    test("bob's library is empty: none of alice's tracks are left", () async {
      final ProviderContainer c = await aliceSyncedAndLeft();
      client.itemsByKind = <JellyfinItemKind, List<JellyfinItemDto>>{};

      await signInAs(c, bob);

      expect(await jellyfinUris(), isEmpty);
      expect(
        c.read(jellyfinSyncControllerProvider).status,
        JellyfinSyncStatus.success,
      );
      expect(await autoSync.read(), jellyfinAccountFingerprint(bob));
      expect(await owners.read('jellyfin'), jellyfinAccountFingerprint(bob));
    });

    test("bob's first sync fails: none of alice's tracks are left", () async {
      final ProviderContainer c = await aliceSyncedAndLeft();
      client.itemsError = JellyfinException.serverError(500);

      await signInAs(c, bob);

      expect(await jellyfinUris(), isEmpty);
      expect(
        c.read(jellyfinSyncControllerProvider).status,
        JellyfinSyncStatus.error,
      );
      // Not recorded as synced, so bob's next sign-in tries again.
      expect(await autoSync.read(), jellyfinAccountFingerprint(alice));
    });

    test('bob signing in over alice, without signing out, clears her too',
        () async {
      final ProviderContainer c = app();
      await _settle();
      await signInAs(c, alice);
      client.itemsByKind = <JellyfinItemKind, List<JellyfinItemDto>>{};

      await signInAs(c, bob);

      expect(await jellyfinUris(), isEmpty);
    });

    test('alice signing back in keeps her library and syncs nothing', () async {
      final ProviderContainer c = await aliceSyncedAndLeft();
      final int fetches = client.requestedKinds.length;

      await signInAs(c, alice);

      expect(
        await jellyfinUris(),
        unorderedEquals(<String>['jellyfin:a', 'jellyfin:b']),
      );
      expect(client.requestedKinds, hasLength(fetches));
    });

    test('alice back after bob gets her own library, not his', () async {
      // Alice auto-synced first. Bob's first sync failed and he synced by
      // hand, so alice is still the account recorded as auto-synced, but the
      // library holds bob's tracks.
      final ProviderContainer c = await aliceSyncedAndLeft();
      client.itemsError = JellyfinException.serverError(500);
      await signInAs(c, bob);
      client
        ..itemsError = null
        ..itemsByKind = <JellyfinItemKind, List<JellyfinItemDto>>{
          JellyfinItemKind.audio: <JellyfinItemDto>[_audio('x')],
        };
      await c.read(jellyfinSyncControllerProvider.notifier).sync();
      await signOut(c);
      expect(await jellyfinUris(), <String>['jellyfin:x']);
      expect(await autoSync.read(), jellyfinAccountFingerprint(alice));

      client.itemsByKind = <JellyfinItemKind, List<JellyfinItemDto>>{
        JellyfinItemKind.audio: <JellyfinItemDto>[_audio('a'), _audio('b')],
      };
      await signInAs(c, alice);

      expect(
        await jellyfinUris(),
        unorderedEquals(<String>['jellyfin:a', 'jellyfin:b']),
      );
    });

    test('a write already under way lands before the clear, not after it',
        () async {
      final _GatedCatalog gated = _GatedCatalog(catalog);
      final ProviderContainer c = _container(
        authenticator: auth,
        repository: gated,
        autoSyncStore: autoSync,
        owners: owners,
        client: client,
      );
      c.read(jellyfinSettingsControllerProvider);
      await _settle();

      // Alice's sync is writing her library when she signs out and bob signs
      // in (to an empty library).
      gated.gate = Completer<void>();
      auth.session = alice;
      await _signIn(c);
      await _drainAutoSync();
      expect(gated.parked, isTrue);
      await signOut(c);
      client.itemsByKind = <JellyfinItemKind, List<JellyfinItemDto>>{};
      auth.session = bob;
      await _signIn(c, url: 'other.example.com', username: 'bob');
      // Bob's sign-in gets as far as it can before alice's write lands.
      await _drainAutoSync();
      gated.gate!.complete();
      await _drainAutoSync();

      expect(await jellyfinUris(), isEmpty);
    });

    test(
        "bob's tracks are never written while the record still says they are "
        "alice's", () async {
      final _FlakyOwners flaky = _FlakyOwners();
      owners = flaky;
      final ProviderContainer c = await aliceSyncedAndLeft();
      flaky.failWrites = true;

      await signInAs(c, bob);

      // Her tracks are gone, and his sync failed rather than write his
      // tracks under her name.
      expect(await jellyfinUris(), isEmpty);
      expect(await owners.read('jellyfin'), jellyfinAccountFingerprint(alice));
      expect(
        c.read(jellyfinSyncControllerProvider).status,
        JellyfinSyncStatus.error,
      );

      // Once the record can be saved, his next sync takes the library over.
      flaky.failWrites = false;
      await c.read(jellyfinSyncControllerProvider.notifier).sync();

      expect(await jellyfinUris(), hasLength(2));
      expect(await owners.read('jellyfin'), jellyfinAccountFingerprint(bob));
    });

    group('the play queue goes with the library (#767)', () {
      const Track aliceA = Track(id: 'a', title: 'Alice a', uri: 'jellyfin:a');
      const Track aliceB = Track(id: 'b', title: 'Alice b', uri: 'jellyfin:b');
      const Track onDisk = Track(id: '/m/x.flac', title: 'x', uri: '/m/x.flac');

      late FakePlaybackController player;

      setUp(() => player = FakePlaybackController());
      tearDown(() => player.dispose());

      List<Override> withPlayer() => <Override>[
            localPlaybackControllerProvider.overrideWithValue(player),
          ];

      test("bob taking over takes alice's songs out, the playing one too",
          () async {
        final ProviderContainer c =
            await aliceSyncedAndLeft(overrides: withPlayer());
        c.read(localPlaybackControllerProvider);
        await player.playTracks(<Track>[aliceA, onDisk, aliceB]);
        client.itemsByKind = <JellyfinItemKind, List<JellyfinItemDto>>{};

        await signInAs(c, bob);

        expect(player.removeTracksCount, 1);
        expect(player.state.currentTrack?.uri, onDisk.uri);
        expect(player.state.upNext, isEmpty);
        expect(player.state.previous, isEmpty);
      });

      test('alice signing back in keeps her songs queued', () async {
        final ProviderContainer c =
            await aliceSyncedAndLeft(overrides: withPlayer());
        c.read(localPlaybackControllerProvider);
        await player.playTracks(<Track>[aliceA, aliceB]);

        await signInAs(c, alice);

        expect(player.removeTracksCount, 0);
        expect(player.state.currentTrack?.uri, aliceA.uri);
        expect(
          <String>[for (final Track t in player.state.upNext) t.uri],
          <String>[aliceB.uri],
        );
      });

      test('with no player built yet, none is built to empty it', () async {
        bool built = false;
        final ProviderContainer c = await aliceSyncedAndLeft(
          overrides: <Override>[
            localPlaybackControllerProvider.overrideWith((Ref ref) {
              built = true;
              return player;
            }),
          ],
        );
        client.itemsByKind = <JellyfinItemKind, List<JellyfinItemDto>>{};

        await signInAs(c, bob);

        expect(await jellyfinUris(), isEmpty);
        expect(built, isFalse);
      });
    });

    group('a library synced before the owner was recorded', () {
      Future<void> seedAlicesLibrary() => catalog.upsertCatalog(
            sourceId: 'jellyfin',
            tracks: <Track>[
              const Track(id: 'a', title: 'a', uri: 'jellyfin:a'),
              const Track(id: 'b', title: 'b', uri: 'jellyfin:b'),
            ],
            albums: const <Album>[],
            artists: const <Artist>[],
          );

      test('is kept for the account that auto-synced it', () async {
        await seedAlicesLibrary();
        autoSync = InMemoryJellyfinAutoSyncStore(
          jellyfinAccountFingerprint(alice),
        );
        final ProviderContainer c = app();
        await _settle();
        final int fetches = client.requestedKinds.length;

        await signInAs(c, alice);

        expect(await jellyfinUris(), hasLength(2));
        expect(client.requestedKinds, hasLength(fetches));
        expect(
          await owners.read('jellyfin'),
          jellyfinAccountFingerprint(alice),
        );
      });

      test('is cleared for another account', () async {
        await seedAlicesLibrary();
        autoSync = InMemoryJellyfinAutoSyncStore(
          jellyfinAccountFingerprint(alice),
        );
        client.itemsByKind = <JellyfinItemKind, List<JellyfinItemDto>>{};
        final ProviderContainer c = app();
        await _settle();

        await signInAs(c, bob);

        expect(await jellyfinUris(), isEmpty);
      });

      test("is recorded as the signed-in account's when it signs out",
          () async {
        // Nothing to guess from: no auto-sync was ever recorded. Alice is
        // signed in since before the update, and signs out.
        await seedAlicesLibrary();
        final ProviderContainer c = app(restoredSession: alice);
        await c
            .read(jellyfinSettingsControllerProvider.notifier)
            .ensureLoaded();
        await signOut(c);
        client.itemsByKind = <JellyfinItemKind, List<JellyfinItemDto>>{};

        await signInAs(c, bob);

        expect(await jellyfinUris(), isEmpty);
      });
    });
  });
}

/// The owner store, with writes that can be made to fail (a full disk, a
/// storage error), so a test can see what a takeover does when the record of
/// whose tracks the slice holds can't be saved.
class _FlakyOwners extends InMemoryRemoteCatalogOwnerStore {
  bool failWrites = false;

  @override
  Future<void> write(String sourceId, String fingerprint) {
    if (failWrites) throw StateError('could not save');
    return super.write(sourceId, fingerprint);
  }
}

/// The in-memory catalog, with a gate a sync's write can be held at, so a
/// test can sign in another account while that write is under way.
class _GatedCatalog implements MusicLibraryRepository {
  _GatedCatalog(this._inner);

  final InMemoryMusicLibraryRepository _inner;
  Completer<void>? gate;
  bool parked = false;

  @override
  Future<void> upsertCatalog({
    required String sourceId,
    required List<Track> tracks,
    required List<Album> albums,
    required List<Artist> artists,
  }) async {
    final Completer<void>? held = gate;
    if (held != null && tracks.isNotEmpty) {
      parked = true;
      await held.future;
    }
    await _inner.upsertCatalog(
      sourceId: sourceId,
      tracks: tracks,
      albums: albums,
      artists: artists,
    );
  }

  @override
  Future<List<Track>> getAllTracks() => _inner.getAllTracks();

  @override
  Future<List<Album>> getAllAlbums() => _inner.getAllAlbums();

  @override
  Future<List<Artist>> getAllArtists() => _inner.getAllArtists();

  @override
  Future<Track?> getTrackByUri(String uri) => _inner.getTrackByUri(uri);

  @override
  Future<void> removeTracks(List<String> trackIds) =>
      _inner.removeTracks(trackIds);
}
