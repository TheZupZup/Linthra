import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/favorites_repository.dart';
import 'package:linthra/core/repositories/jellyfin_session_store.dart';
import 'package:linthra/core/repositories/playlist_repository.dart';
import 'package:linthra/core/repositories/remote_sync_result.dart';
import 'package:linthra/core/repositories/secure_storage_exception.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_index.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_record.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/data/repositories/favorites_repository_provider.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_session_store.dart';
import 'package:linthra/data/repositories/jellyfin_session_store_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/data/repositories/remote_cache_index_provider.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_providers.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_state.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_sync_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_sync_state.dart';

import '../../../core/services/remote_cache/fake_remote_cache_store.dart';

import '../../../core/sources/jellyfin/fake_jellyfin_client.dart';
import 'fake_jellyfin_authenticator.dart';

const _session = JellyfinSession(
  baseUrl: 'https://music.example.com',
  userId: 'user-1',
  accessToken: 'tok',
  deviceId: 'device-1',
  userName: 'alice',
  serverName: 'Home',
);

/// Lets the controller's async `build`/`_loadPersisted` settle.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

/// Two Jellyfin servers behind one client: each base URL answers
/// `/System/Info/Public` with its own name and version, the way two real
/// servers do. Signing in goes through the real [JellyfinAuthenticator].
class _TwoServerClient extends FakeJellyfinClient {
  _TwoServerClient(this.servers);

  /// What each server reports, by normalized base URL.
  final Map<String, JellyfinServerInfo> servers;

  @override
  Future<JellyfinServerInfo> fetchServerInfo(String baseUrl) async {
    lastBaseUrl = baseUrl;
    final JellyfinServerInfo? info = servers[baseUrl];
    if (info == null) throw JellyfinException.notReachable();
    return info;
  }
}

/// Records [clearRemote] calls so a sign-out test can prove the controller tears
/// down this account's server-synced favourites.
class _SpyFavoritesRepository implements FavoritesRepository {
  int clearRemoteCalls = 0;
  String? lastClearScheme;

  @override
  Future<void> clearRemote({String? providerScheme}) async {
    clearRemoteCalls++;
    lastClearScheme = providerScheme;
  }

  @override
  Stream<Set<String>> get favoritesStream => const Stream<Set<String>>.empty();

  @override
  bool isFavorite(String trackId) => false;

  @override
  Future<void> setFavorite(Track track, bool favorite) async {}

  @override
  Future<FavoritesSyncResult> refreshFromRemote(
          {String? providerScheme}) async =>
      const FavoritesSyncResult.notConfigured();
}

/// Records [clearRemote] calls so a sign-out test can prove the controller also
/// drops this account's imported Jellyfin playlists.
class _SpyPlaylistRepository implements PlaylistRepository {
  int clearRemoteCalls = 0;
  PlaylistSource? lastClearSource;

  @override
  Future<void> clearRemote({PlaylistSource? source}) async {
    clearRemoteCalls++;
    lastClearSource = source;
  }

  @override
  Stream<List<Playlist>> get playlistsStream =>
      const Stream<List<Playlist>>.empty();

  @override
  Future<List<Playlist>> getAllPlaylists() async => const <Playlist>[];

  @override
  Future<Playlist?> getPlaylistById(String id) async => null;

  @override
  Future<PlaylistSyncResult> refreshFromRemote(
          {PlaylistSource? source}) async =>
      const PlaylistSyncResult.notConfigured();

  @override
  Future<Playlist> createPlaylist(
    String name, {
    String? description,
    PlaylistSource source = PlaylistSource.local,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> renamePlaylist(String id, String name, {String? description}) =>
      throw UnimplementedError();

  @override
  Future<void> deletePlaylist(String id) => throw UnimplementedError();

  @override
  Future<void> addTrack(String playlistId, String trackId) =>
      throw UnimplementedError();

  @override
  Future<void> addTracks(String playlistId, List<String> trackIds) =>
      throw UnimplementedError();

  @override
  Future<List<int>> removeTrack(String playlistId, String trackId) =>
      throw UnimplementedError();

  @override
  Future<void> restoreTrack(
    String playlistId,
    String trackUri,
    List<int> positions,
  ) =>
      throw UnimplementedError();

  @override
  Future<void> reorderTracks(
    String playlistId,
    int oldIndex,
    int newIndex, {
    List<String>? shown,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> markSyncState(
    String id,
    PlaylistSyncState state, {
    String? error,
  }) =>
      throw UnimplementedError();

  @override
  List<String> entriesHere(Playlist playlist) => playlist.trackIds;
}

/// A session store standing in for a platform keyring that cannot be used:
/// missing, locked, or refused by a sandbox. It fails exactly the way
/// [SecureJellyfinSessionStore] does through [SecureSessionStorage] (a typed
/// [SecureStorageException]), so these tests exercise the controller's real
/// failure path rather than a generic thrown object.
class _UnusableKeyringStore implements JellyfinSessionStore {
  _UnusableKeyringStore({
    JellyfinSession? initialSession,
    this.readFailure,
    this.writeFailure,
    this.clearFailure,
    this.readGate,
  }) : _session = initialSession;

  JellyfinSession? _session;
  final SecureStorageException? readFailure;
  final SecureStorageException? writeFailure;
  final SecureStorageException? clearFailure;

  /// Holds the restore read open, the way a keyring that is waiting on an
  /// unlock prompt does.
  final Completer<void>? readGate;

  @override
  Future<JellyfinSession?> read() async {
    if (readGate != null) await readGate!.future;
    if (readFailure != null) throw readFailure!;
    return _session;
  }

  @override
  Future<void> write(JellyfinSession session) async {
    if (writeFailure != null) throw writeFailure!;
    _session = session;
  }

  @override
  Future<void> clear() async {
    if (clearFailure != null) throw clearFailure!;
    _session = null;
  }
}

const SecureStorageException _lockedRead = SecureStorageException(
  operation: SecureStorageOperation.read,
  failure: SecureStorageFailure.locked,
);

const SecureStorageException _unavailableWrite = SecureStorageException(
  operation: SecureStorageOperation.write,
  failure: SecureStorageFailure.unavailable,
);

const SecureStorageException _lockedDelete = SecureStorageException(
  operation: SecureStorageOperation.delete,
  failure: SecureStorageFailure.locked,
);

ProviderContainer _container({
  FakeJellyfinAuthenticator? authenticator,
  JellyfinSessionStore? store,
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      jellyfinAuthenticatorProvider
          .overrideWithValue(authenticator ?? FakeJellyfinAuthenticator()),
      jellyfinSessionStoreProvider
          .overrideWithValue(store ?? InMemoryJellyfinSessionStore()),
      jellyfinClientProvider.overrideWithValue(FakeJellyfinClient()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('JellyfinSettingsController load', () {
    test('starts disconnected when nothing is persisted', () async {
      final container = _container();
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      expect(
        container.read(jellyfinSettingsControllerProvider).phase,
        JellyfinConnectionPhase.disconnected,
      );
    });

    test('ensureLoaded readies the signed-in source before first play',
        () async {
      // Mirrors what `main` awaits at startup: after ensureLoaded() resolves,
      // the persisted session is live and the Jellyfin source is available, so
      // the first remote track can stream without racing the background load
      // (the bug that made streaming look like it required downloading first).
      final container = _container(
        store: InMemoryJellyfinSessionStore(initialSession: _session),
      );

      await container
          .read(jellyfinSettingsControllerProvider.notifier)
          .ensureLoaded();

      expect(
        container.read(jellyfinSettingsControllerProvider).phase,
        JellyfinConnectionPhase.connected,
      );
      expect(container.read(jellyfinMusicSourceProvider), isNotNull);
    });

    test('loads a persisted session as connected', () async {
      final container = _container(
        store: InMemoryJellyfinSessionStore(initialSession: _session),
      );
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      final state = container.read(jellyfinSettingsControllerProvider);
      expect(state.phase, JellyfinConnectionPhase.connected);
      expect(state.username, 'alice');
      expect(state.serverName, 'Home');
      expect(state.baseUrl, 'https://music.example.com');
      expect(
        container.read(jellyfinSettingsControllerProvider.notifier).session,
        _session,
      );
    });
  });

  group('testConnection', () {
    test('reports the reached server on success', () async {
      final auth = FakeJellyfinAuthenticator();
      final container = _container(authenticator: auth);
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      final ok = await container
          .read(jellyfinSettingsControllerProvider.notifier)
          .testConnection('music.example.com');

      expect(ok, isTrue);
      final state = container.read(jellyfinSettingsControllerProvider);
      expect(state.phase, JellyfinConnectionPhase.tested);
      expect(state.serverName, 'My Server');
      expect(state.statusMessage, contains('My Server'));
      expect(auth.lastTestUrl, 'music.example.com');
    });

    test('surfaces a friendly error on failure', () async {
      final auth = FakeJellyfinAuthenticator(
          testError: JellyfinException.notReachable());
      final container = _container(authenticator: auth);
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      final ok = await container
          .read(jellyfinSettingsControllerProvider.notifier)
          .testConnection('bad');

      expect(ok, isFalse);
      final state = container.read(jellyfinSettingsControllerProvider);
      expect(state.phase, JellyfinConnectionPhase.disconnected);
      expect(state.errorMessage, isNotNull);
    });
  });

  group('signIn', () {
    test('persists the session and connects on success', () async {
      final store = InMemoryJellyfinSessionStore();
      final auth = FakeJellyfinAuthenticator(session: _session);
      final container = _container(authenticator: auth, store: store);
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      final ok = await container
          .read(jellyfinSettingsControllerProvider.notifier)
          .signIn(url: 'music.example.com', username: 'alice', password: 'pw');

      expect(ok, isTrue);
      final state = container.read(jellyfinSettingsControllerProvider);
      expect(state.phase, JellyfinConnectionPhase.connected);
      expect(state.username, 'alice');
      expect(await store.read(), _session);
      // The password reached the authenticator but is not in the persisted
      // session or the UI state.
      expect(auth.lastPassword, 'pw');
      expect(state.statusMessage, isNot(contains('pw')));
    });

    test('carries a previously tested server name into sign-in', () async {
      final auth = FakeJellyfinAuthenticator();
      final container = _container(authenticator: auth);
      container.read(jellyfinSettingsControllerProvider);
      await _settle();
      final notifier =
          container.read(jellyfinSettingsControllerProvider.notifier);

      await notifier.testConnection('music.example.com');
      await notifier.signIn(
        url: 'music.example.com',
        username: 'alice',
        password: 'pw',
      );

      // The tested server info (name + version) is carried into sign-in so it
      // needn't re-read it and the session records the version.
      expect(auth.lastServerInfo?.serverName, 'My Server');
      expect(auth.lastServerInfo?.version, '10.9.0');
    });

    // The address can be edited between a test and the sign-in: a listener
    // with two servers tests one, then types the other one's address. The
    // signed-in card, the saved session and the diagnostics have to describe
    // the server that was signed in to, not the one tested before it.
    test('a sign-in to another address than the one tested records that server',
        () async {
      final _TwoServerClient client =
          _TwoServerClient(<String, JellyfinServerInfo>{
        'https://home.example.com':
            const JellyfinServerInfo(serverName: 'Home', version: '10.8.13'),
        'https://office.example.com':
            const JellyfinServerInfo(serverName: 'Office', version: '10.10.3'),
      });
      final store = InMemoryJellyfinSessionStore();
      final container = ProviderContainer(
        overrides: <Override>[
          jellyfinClientProvider.overrideWithValue(client),
          jellyfinSessionStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(container.dispose);
      final notifier =
          container.read(jellyfinSettingsControllerProvider.notifier);
      await _settle();

      expect(await notifier.testConnection('home.example.com'), isTrue);
      expect(
        await notifier.signIn(
          url: 'office.example.com',
          username: 'alice',
          password: 'pw',
        ),
        isTrue,
      );

      final state = container.read(jellyfinSettingsControllerProvider);
      expect(state.baseUrl, 'https://office.example.com');
      expect(state.serverName, 'Office');
      expect(state.serverVersion, '10.10.3');
      expect(state.statusMessage, 'Signed in as alice on Office.');
      final JellyfinSession? saved = await store.read();
      expect(saved?.serverName, 'Office');
      expect(saved?.serverVersion, '10.10.3');
    });

    test('does not persist anything on failure', () async {
      final store = InMemoryJellyfinSessionStore();
      final auth = FakeJellyfinAuthenticator(
        signInError: JellyfinException.unauthorized(),
      );
      final container = _container(authenticator: auth, store: store);
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      final ok = await container
          .read(jellyfinSettingsControllerProvider.notifier)
          .signIn(url: 'music.example.com', username: 'alice', password: 'bad');

      expect(ok, isFalse);
      expect(await store.read(), isNull);
      final state = container.read(jellyfinSettingsControllerProvider);
      expect(state.phase, JellyfinConnectionPhase.disconnected);
      expect(state.errorMessage, isNotNull);
    });
  });

  group('clear', () {
    test('wipes the stored session and resets to disconnected', () async {
      final store = InMemoryJellyfinSessionStore(initialSession: _session);
      final container = _container(store: store);
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      await container.read(jellyfinSettingsControllerProvider.notifier).clear();

      expect(await store.read(), isNull);
      final state = container.read(jellyfinSettingsControllerProvider);
      expect(state.phase, JellyfinConnectionPhase.disconnected);
      expect(state.statusMessage, contains('cleared'));
      expect(
        container.read(jellyfinSettingsControllerProvider.notifier).session,
        isNull,
      );
    });

    test("sign-out drops this account's server-synced favourites", () async {
      final favorites = _SpyFavoritesRepository();
      final container = ProviderContainer(overrides: <Override>[
        jellyfinAuthenticatorProvider
            .overrideWithValue(FakeJellyfinAuthenticator()),
        jellyfinSessionStoreProvider.overrideWithValue(
          InMemoryJellyfinSessionStore(initialSession: _session),
        ),
        jellyfinClientProvider.overrideWithValue(FakeJellyfinClient()),
        favoritesRepositoryProvider.overrideWithValue(favorites),
      ]);
      addTearDown(container.dispose);
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      await container.read(jellyfinSettingsControllerProvider.notifier).clear();

      // The account's hearts are cleared so they can't linger — or be re-pushed
      // to a different account — after signing out.
      expect(favorites.clearRemoteCalls, 1);
    });

    test("sign-out drops this account's imported Jellyfin playlists", () async {
      final playlists = _SpyPlaylistRepository();
      final container = ProviderContainer(overrides: <Override>[
        jellyfinAuthenticatorProvider
            .overrideWithValue(FakeJellyfinAuthenticator()),
        jellyfinSessionStoreProvider.overrideWithValue(
          InMemoryJellyfinSessionStore(initialSession: _session),
        ),
        jellyfinClientProvider.overrideWithValue(FakeJellyfinClient()),
        playlistRepositoryProvider.overrideWithValue(playlists),
      ]);
      addTearDown(container.dispose);
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      await container.read(jellyfinSettingsControllerProvider.notifier).clear();

      // The account's imported Jellyfin playlists are dropped so they can't
      // linger after signing out; local-only playlists are kept (repository).
      expect(playlists.clearRemoteCalls, 1);
    });

    test("sign-out drops this account's prepared remote-cache records",
        () async {
      final store = FakeRemoteCacheStore(seed: <RemoteCacheRecord>[
        fakeRemoteCacheRecord('jellyfin:a'),
        fakeRemoteCacheRecord('jellyfin:b'),
        fakeRemoteCacheRecord('plex:1'),
      ]);
      final index = RemoteCacheIndex(store: store);
      final container = ProviderContainer(overrides: <Override>[
        jellyfinAuthenticatorProvider
            .overrideWithValue(FakeJellyfinAuthenticator()),
        jellyfinSessionStoreProvider.overrideWithValue(
          InMemoryJellyfinSessionStore(initialSession: _session),
        ),
        jellyfinClientProvider.overrideWithValue(FakeJellyfinClient()),
        remoteCacheIndexProvider.overrideWithValue(index),
      ]);
      addTearDown(container.dispose);
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      await container.read(jellyfinSettingsControllerProvider.notifier).clear();

      // Only this provider's prepared-track records are removed (memory + disk);
      // another provider's records are left untouched.
      expect(index.records.map((RemoteCacheRecord r) => r.value), <String>[
        'plex:1',
      ]);
      expect(store.saved.map((RemoteCacheRecord r) => r.value), <String>[
        'plex:1',
      ]);
    });

    test('sign-out resets the (now stale) sync status', () async {
      final container = _container(
        store: InMemoryJellyfinSessionStore(initialSession: _session),
      );
      final notifier =
          container.read(jellyfinSettingsControllerProvider.notifier);
      await _settle();
      // Run a sync so the sync controller holds a non-idle status message.
      await container.read(jellyfinSyncControllerProvider.notifier).sync();
      expect(
        container.read(jellyfinSyncControllerProvider).status,
        isNot(JellyfinSyncStatus.idle),
      );

      await notifier.clear();
      await _settle();

      // The stale "Synced …" status is gone, so it can't reappear on a later
      // sign-in into this (or a different) account.
      final synced = container.read(jellyfinSyncControllerProvider);
      expect(synced.status, JellyfinSyncStatus.idle);
      expect(synced.message, isNull);
    });
  });

  group('server capability + diagnostics', () {
    test('captures the server version and product on a successful test',
        () async {
      final auth = FakeJellyfinAuthenticator(
        serverInfo: const JellyfinServerInfo(
          serverName: 'Home',
          version: '10.9.11',
          productName: 'Jellyfin Server',
        ),
      );
      final container = _container(authenticator: auth);
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      await container
          .read(jellyfinSettingsControllerProvider.notifier)
          .testConnection('music.example.com');

      final state = container.read(jellyfinSettingsControllerProvider);
      expect(state.serverVersion, '10.9.11');
      expect(state.productName, 'Jellyfin Server');
    });

    test('persists the server version into the saved session', () async {
      final store = InMemoryJellyfinSessionStore();
      final auth = FakeJellyfinAuthenticator(
        serverInfo:
            const JellyfinServerInfo(serverName: 'Home', version: '10.9.11'),
      );
      final container = _container(authenticator: auth, store: store);
      final notifier =
          container.read(jellyfinSettingsControllerProvider.notifier);
      await _settle();

      await notifier.testConnection('music.example.com');
      await notifier.signIn(
        url: 'music.example.com',
        username: 'alice',
        password: 'pw',
      );

      final saved = await store.read();
      expect(saved!.serverVersion, '10.9.11');
    });

    test('builds a secret-free diagnostics report', () async {
      const session = JellyfinSession(
        baseUrl: 'https://music.example.com/jellyfin',
        userId: 'user-1',
        accessToken: 'tok-secret-value',
        deviceId: 'device-1',
        userName: 'alice',
        serverName: 'Home',
        serverVersion: '10.9.11',
      );
      final container = _container(
        store: InMemoryJellyfinSessionStore(initialSession: session),
      );
      final notifier =
          container.read(jellyfinSettingsControllerProvider.notifier);
      await notifier.ensureLoaded();

      final report = notifier.diagnosticsReport();

      // It carries the useful, non-secret context...
      expect(report, contains('App version:'));
      expect(report, contains('Connection: connected'));
      expect(report, contains('10.9.11'));
      expect(report, contains('music.example.com'));
      // ...and never the token, an Authorization header, or a full URL.
      expect(report, isNot(contains('tok-secret-value')));
      expect(report, isNot(contains('api_key')));
      expect(report, isNot(contains('/jellyfin')));
    });

    test('a failed test of a different address reports no stale server',
        () async {
      final auth = FakeJellyfinAuthenticator(
        serverInfo:
            const JellyfinServerInfo(serverName: 'Home', version: '10.9.11'),
      );
      final container = _container(authenticator: auth);
      final notifier =
          container.read(jellyfinSettingsControllerProvider.notifier);
      await _settle();

      // A successful test of one server records its name/version (but we never
      // sign in, so we stay disconnected).
      await notifier.testConnection('home.example.com');
      expect(
        container.read(jellyfinSettingsControllerProvider).serverName,
        'Home',
      );

      // Now a test of a *different* address fails.
      auth.testError = JellyfinException.notReachable();
      await notifier.testConnection('other.example.com');

      final report = notifier.diagnosticsReport();
      // Diagnostics must describe the address that was just tried — not carry
      // the previously-seen server's identity into an unrelated failure.
      expect(report, isNot(contains('Home')));
      expect(report, isNot(contains('10.9.11')));
    });

    test('records the error kind for diagnostics on a failed sign-in',
        () async {
      final auth = FakeJellyfinAuthenticator(
        signInError: JellyfinException.unauthorized(),
      );
      final container = _container(authenticator: auth);
      final notifier =
          container.read(jellyfinSettingsControllerProvider.notifier);
      await _settle();

      await notifier.signIn(
        url: 'music.example.com',
        username: 'alice',
        password: 'bad',
      );

      expect(
        container.read(jellyfinSettingsControllerProvider).errorKind,
        JellyfinErrorKind.unauthorized,
      );
      expect(
          notifier.diagnosticsReport(), contains('Last error: unauthorized'));
    });
  });

  group('jellyfinMusicSourceProvider', () {
    test('is null when disconnected and a source once connected', () async {
      final container = _container(
        authenticator: FakeJellyfinAuthenticator(session: _session),
      );
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      expect(container.read(jellyfinMusicSourceProvider), isNull);

      await container
          .read(jellyfinSettingsControllerProvider.notifier)
          .signIn(url: 'music.example.com', username: 'alice', password: 'pw');

      final source = container.read(jellyfinMusicSourceProvider);
      expect(source, isNotNull);
      expect(source!.session, _session);
      expect(source.id, 'jellyfin');
    });
  });

  group('JellyfinSettingsController secure storage failures', () {
    test(
        'a keyring it cannot read reports a restore error, not a silent '
        'sign-out', () async {
      final container = _container(
        store: _UnusableKeyringStore(
          initialSession: _session,
          readFailure: _lockedRead,
        ),
      );
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      final state = container.read(jellyfinSettingsControllerProvider);
      expect(state.phase, JellyfinConnectionPhase.disconnected);
      expect(
        state.errorMessage,
        contains("Couldn't restore your saved Jellyfin sign-in"),
      );
      // The cause is actionable, not a shrug.
      expect(state.errorMessage, contains('Unlock your keyring'));
    });

    test(
        'a sign-in that cannot be saved fails with a storage error and keeps '
        'no session', () async {
      final store = _UnusableKeyringStore(writeFailure: _unavailableWrite);
      final container = _container(
        authenticator: FakeJellyfinAuthenticator(session: _session),
        store: store,
      );
      final notifier =
          container.read(jellyfinSettingsControllerProvider.notifier);
      await _settle();

      final ok = await notifier.signIn(
        url: 'music.example.com',
        username: 'alice',
        password: 'hunter2',
      );

      expect(ok, isFalse);
      final state = container.read(jellyfinSettingsControllerProvider);
      expect(state.phase, JellyfinConnectionPhase.disconnected);
      expect(
        state.errorMessage,
        contains("Couldn't save your Jellyfin sign-in on this device"),
      );
      expect(state.errorMessage, contains('no keyring available'));
      // A session that could not be persisted is not adopted: it would look
      // signed in now and be gone after a restart.
      expect(notifier.session, isNull);
      expect(container.read(jellyfinMusicSourceProvider), isNull);
      expect(await store.read(), isNull);
    });

    test('the storage error carries no token and no password', () async {
      final container = _container(
        authenticator: FakeJellyfinAuthenticator(session: _session),
        store: _UnusableKeyringStore(writeFailure: _unavailableWrite),
      );
      final notifier =
          container.read(jellyfinSettingsControllerProvider.notifier);
      await _settle();

      await notifier.signIn(
        url: 'music.example.com',
        username: 'alice',
        password: 'hunter2',
      );

      final state = container.read(jellyfinSettingsControllerProvider);
      expect(state.errorMessage, isNot(contains('hunter2')));
      expect(state.errorMessage, isNot(contains(_session.accessToken)));
      expect(notifier.diagnosticsReport(), isNot(contains('hunter2')));
      expect(
        notifier.diagnosticsReport(),
        isNot(contains(_session.accessToken)),
      );
    });

    test('a restore failure never overwrites a sign-in that got there first',
        () async {
      // A locked keyring can hold the startup read open for as long as the
      // unlock prompt sits there. If the user signs in meanwhile, the late
      // failure must not replace their connected card with a restore error.
      final gate = Completer<void>();
      final container = _container(
        authenticator: FakeJellyfinAuthenticator(session: _session),
        store: _UnusableKeyringStore(readFailure: _lockedRead, readGate: gate),
      );
      final notifier =
          container.read(jellyfinSettingsControllerProvider.notifier);

      final ok = await notifier.signIn(
        url: 'music.example.com',
        username: 'alice',
        password: 'hunter2',
      );
      expect(ok, isTrue);

      gate.complete();
      await _settle();

      final state = container.read(jellyfinSettingsControllerProvider);
      expect(state.phase, JellyfinConnectionPhase.connected);
      expect(state.errorMessage, isNull);
    });

    test('a sign-out the keyring refuses says so instead of pretending',
        () async {
      final store = _UnusableKeyringStore(
        initialSession: _session,
        clearFailure: _lockedDelete,
      );
      final container = _container(store: store);
      final notifier =
          container.read(jellyfinSettingsControllerProvider.notifier);
      await notifier.ensureLoaded();

      await notifier.clear();

      final state = container.read(jellyfinSettingsControllerProvider);
      expect(
        state.errorMessage,
        contains("Couldn't remove your Jellyfin sign-in from this device"),
      );
      // Still signed in, because the credential really is still in the
      // keyring. Retrying after unlocking completes the same sign-out.
      expect(state.phase, JellyfinConnectionPhase.connected);
      expect(await store.read(), _session);
    });
  });
}
