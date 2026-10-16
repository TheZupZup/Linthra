import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/secure_storage_exception.dart';
import 'package:linthra/core/repositories/subsonic_session_store.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_entry.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_index.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_key.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_record.dart';
import 'package:linthra/core/services/remote_cache/remote_playback_cache.dart';
import 'package:linthra/core/sources/subsonic/subsonic_exception.dart';
import 'package:linthra/core/sources/subsonic/subsonic_stream_relay.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_session_store.dart';
import 'package:linthra/data/repositories/remote_cache_index_provider.dart';
import 'package:linthra/data/repositories/subsonic_session_store_provider.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_controller.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_providers.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_state.dart';

import '../../../core/services/remote_cache/fake_remote_cache_store.dart';
import '../../../core/sources/subsonic/fake_subsonic_client.dart';

const _session = SubsonicSession(
  baseUrl: 'https://music.example.com',
  username: 'alice',
  salt: 'salt1',
  token: 'tok1',
  serverType: 'navidrome',
  serverVersion: '0.52.0',
);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

/// A session store standing in for a platform keyring that cannot be used:
/// missing, locked, or refused by a sandbox. It fails exactly the way
/// [SecureSubsonicSessionStore] does through [SecureSessionStorage] (a typed
/// [SecureStorageException]), so these tests exercise the controller's real
/// failure path rather than a generic thrown object.
class _UnusableKeyringStore implements SubsonicSessionStore {
  _UnusableKeyringStore({
    SubsonicSession? initialSession,
    this.readFailure,
    this.writeFailure,
    this.clearFailure,
    this.readGate,
  }) : _session = initialSession;

  SubsonicSession? _session;
  final SecureStorageException? readFailure;
  final SecureStorageException? writeFailure;
  final SecureStorageException? clearFailure;

  /// Holds the restore read open, the way a keyring that is waiting on an
  /// unlock prompt does.
  final Completer<void>? readGate;

  @override
  Future<SubsonicSession?> read() async {
    if (readGate != null) await readGate!.future;
    if (readFailure != null) throw readFailure!;
    return _session;
  }

  @override
  Future<void> write(SubsonicSession session) async {
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
  FakeSubsonicClient? client,
  SubsonicSessionStore? store,
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      subsonicClientProvider.overrideWithValue(client ?? FakeSubsonicClient()),
      subsonicSessionStoreProvider
          .overrideWithValue(store ?? InMemorySubsonicSessionStore()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('load', () {
    test('starts disconnected when nothing is persisted', () async {
      final container = _container();
      container.read(subsonicSettingsControllerProvider);
      await _settle();
      expect(
        container.read(subsonicSettingsControllerProvider).phase,
        SubsonicConnectionPhase.disconnected,
      );
    });

    test('ensureLoaded readies the signed-in source', () async {
      final container = _container(
        store: InMemorySubsonicSessionStore(initialSession: _session),
      );

      await container
          .read(subsonicSettingsControllerProvider.notifier)
          .ensureLoaded();

      expect(
        container.read(subsonicSettingsControllerProvider).phase,
        SubsonicConnectionPhase.connected,
      );
      expect(container.read(subsonicMusicSourceProvider), isNotNull);
    });
  });

  group('testConnection', () {
    test('reports the reached product on success', () async {
      final container = _container();
      final notifier =
          container.read(subsonicSettingsControllerProvider.notifier);
      await _settle();

      final ok = await notifier.testConnection(
        url: 'music.example.com',
        username: 'alice',
        password: 'hunter2',
      );

      expect(ok, isTrue);
      final state = container.read(subsonicSettingsControllerProvider);
      expect(state.phase, SubsonicConnectionPhase.tested);
      expect(state.statusMessage, contains('Navidrome'));
    });

    test('surfaces a friendly error on failure', () async {
      final container = _container(
        client: FakeSubsonicClient(pingError: SubsonicException.unauthorized()),
      );
      final notifier =
          container.read(subsonicSettingsControllerProvider.notifier);
      await _settle();

      final ok = await notifier.testConnection(
        url: 'music.example.com',
        username: 'alice',
        password: 'wrong',
      );

      expect(ok, isFalse);
      final state = container.read(subsonicSettingsControllerProvider);
      expect(state.phase, SubsonicConnectionPhase.disconnected);
      expect(state.errorMessage, isNotNull);
    });
  });

  group('signIn', () {
    test('persists a credential-only session and never leaks the password',
        () async {
      final store = InMemorySubsonicSessionStore();
      final client = FakeSubsonicClient();
      final container = _container(client: client, store: store);
      final notifier =
          container.read(subsonicSettingsControllerProvider.notifier);
      await _settle();

      final ok = await notifier.signIn(
        url: 'music.example.com',
        username: 'alice',
        password: 'hunter2',
      );

      expect(ok, isTrue);
      final state = container.read(subsonicSettingsControllerProvider);
      expect(state.phase, SubsonicConnectionPhase.connected);
      expect(state.username, 'alice');

      final saved = await store.read();
      expect(saved, isNotNull);
      // The stored session carries the derived token+salt, never the password.
      expect(saved!.token, client.lastCredentials!.token);
      expect(saved.toJson().values.contains('hunter2'), isFalse);
      // Nor does the displayed state.
      expect(state.statusMessage, isNot(contains('hunter2')));
      expect(state.errorMessage ?? '', isNot(contains('hunter2')));
    });

    test('does not persist anything on failure', () async {
      final store = InMemorySubsonicSessionStore();
      final container = _container(
        client: FakeSubsonicClient(pingError: SubsonicException.unauthorized()),
        store: store,
      );
      final notifier =
          container.read(subsonicSettingsControllerProvider.notifier);
      await _settle();

      final ok = await notifier.signIn(
        url: 'music.example.com',
        username: 'alice',
        password: 'bad',
      );

      expect(ok, isFalse);
      expect(await store.read(), isNull);
      expect(
        container.read(subsonicSettingsControllerProvider).phase,
        SubsonicConnectionPhase.disconnected,
      );
    });
  });

  group('clear', () {
    test('wipes the stored session and resets to disconnected', () async {
      final store = InMemorySubsonicSessionStore(initialSession: _session);
      final container = _container(store: store);
      final notifier =
          container.read(subsonicSettingsControllerProvider.notifier);
      await notifier.ensureLoaded();

      await notifier.clear();

      expect(await store.read(), isNull);
      expect(
        container.read(subsonicSettingsControllerProvider).phase,
        SubsonicConnectionPhase.disconnected,
      );
      expect(notifier.session, isNull);
    });

    test("sign-out drops this account's prepared remote-cache records",
        () async {
      final cacheStore = FakeRemoteCacheStore(seed: <RemoteCacheRecord>[
        fakeRemoteCacheRecord('subsonic:a'),
        fakeRemoteCacheRecord('subsonic:b'),
        fakeRemoteCacheRecord('jellyfin:1'),
      ]);
      final index = RemoteCacheIndex(store: cacheStore);
      final container = ProviderContainer(overrides: <Override>[
        subsonicClientProvider.overrideWithValue(FakeSubsonicClient()),
        subsonicSessionStoreProvider.overrideWithValue(
          InMemorySubsonicSessionStore(initialSession: _session),
        ),
        remoteCacheIndexProvider.overrideWithValue(index),
      ]);
      addTearDown(container.dispose);
      final notifier =
          container.read(subsonicSettingsControllerProvider.notifier);
      await notifier.ensureLoaded();

      await notifier.clear();

      // Only Subsonic's prepared-track records are removed (memory + disk);
      // another provider's records are left untouched.
      expect(index.records.map((RemoteCacheRecord r) => r.value), <String>[
        'jellyfin:1',
      ]);
      expect(cacheStore.saved.map((RemoteCacheRecord r) => r.value), <String>[
        'jellyfin:1',
      ]);
    });
  });

  group('subsonicMusicSourceProvider', () {
    test('is null when disconnected and a source once connected', () async {
      final container = _container();
      container.read(subsonicSettingsControllerProvider);
      await _settle();
      expect(container.read(subsonicMusicSourceProvider), isNull);

      await container.read(subsonicSettingsControllerProvider.notifier).signIn(
            url: 'music.example.com',
            username: 'alice',
            password: 'pw',
          );

      final source = container.read(subsonicMusicSourceProvider);
      expect(source, isNotNull);
      expect(source!.id, 'subsonic');
    });
  });

  group('secure storage failures', () {
    test(
        'a keyring it cannot read reports a restore error, not a silent '
        'sign-out', () async {
      final container = _container(
        store: _UnusableKeyringStore(
          initialSession: _session,
          readFailure: _lockedRead,
        ),
      );
      container.read(subsonicSettingsControllerProvider);
      await _settle();

      final state = container.read(subsonicSettingsControllerProvider);
      expect(state.phase, SubsonicConnectionPhase.disconnected);
      expect(
        state.errorMessage,
        contains("Couldn't restore your saved Navidrome/Subsonic sign-in"),
      );
      expect(state.errorMessage, contains('Unlock your keyring'));
    });

    test(
        'a sign-in that cannot be saved fails with a storage error and keeps '
        'no session', () async {
      final store = _UnusableKeyringStore(writeFailure: _unavailableWrite);
      final container = _container(store: store);
      final notifier =
          container.read(subsonicSettingsControllerProvider.notifier);
      await _settle();

      final ok = await notifier.signIn(
        url: 'music.example.com',
        username: 'alice',
        password: 'hunter2',
      );

      expect(ok, isFalse);
      final state = container.read(subsonicSettingsControllerProvider);
      expect(state.phase, SubsonicConnectionPhase.disconnected);
      expect(
        state.errorMessage,
        contains("Couldn't save your Navidrome/Subsonic sign-in on this "
            'device'),
      );
      expect(state.errorMessage, contains('no keyring available'));
      // Not adopted: a session that could not be persisted would look signed
      // in now and be gone after a restart.
      expect(notifier.session, isNull);
      expect(await store.read(), isNull);
      // And the password that derived the credential never reaches the UI.
      expect(state.errorMessage, isNot(contains('hunter2')));
    });

    test('a restore failure never overwrites a sign-in that got there first',
        () async {
      // A locked keyring can hold the startup read open for as long as the
      // unlock prompt sits there. If the user signs in meanwhile, the late
      // failure must not replace their connected card with a restore error.
      final gate = Completer<void>();
      final container = _container(
        store: _UnusableKeyringStore(readFailure: _lockedRead, readGate: gate),
      );
      final notifier =
          container.read(subsonicSettingsControllerProvider.notifier);

      final ok = await notifier.signIn(
        url: 'music.example.com',
        username: 'alice',
        password: 'hunter2',
      );
      expect(ok, isTrue);

      gate.complete();
      await _settle();

      final state = container.read(subsonicSettingsControllerProvider);
      expect(state.phase, SubsonicConnectionPhase.connected);
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
          container.read(subsonicSettingsControllerProvider.notifier);
      await notifier.ensureLoaded();

      await notifier.clear();

      final state = container.read(subsonicSettingsControllerProvider);
      expect(
        state.errorMessage,
        contains("Couldn't remove your Navidrome/Subsonic sign-in from this "
            'device'),
      );
      // Still signed in, because the credential really is still in the
      // keyring. Retrying after unlocking completes the same sign-out.
      expect(state.phase, SubsonicConnectionPhase.connected);
      expect(await store.read(), _session);
    });
  });

  // Opt-in legacy password sign-in, for a server that refuses the token.
  group('legacy password sign-in', () {
    const passwordSession = SubsonicSession.password(
      baseUrl: 'https://cloud.example.com/apps/music/subsonic',
      username: 'alice',
      password: 'app-password',
      serverType: 'Nextcloud Music',
    );

    test('signs in with the password, keeps it in the store, and says so',
        () async {
      final store = InMemorySubsonicSessionStore();
      final client = FakeSubsonicClient();
      final container = _container(client: client, store: store);
      final notifier =
          container.read(subsonicSettingsControllerProvider.notifier);
      await _settle();

      final ok = await notifier.signIn(
        url: 'https://cloud.example.com/apps/music/subsonic',
        username: 'alice',
        password: 'app-password',
        usePassword: true,
      );

      expect(ok, isTrue);
      expect(client.lastCredentials!.password, 'app-password');
      final saved = await store.read();
      expect(saved!.usesPassword, isTrue);
      final state = container.read(subsonicSettingsControllerProvider);
      expect(state.isConnected, isTrue);
      expect(state.usesPassword, isTrue);
      // The display state still holds no secret.
      expect(state.statusMessage, isNot(contains('app-password')));
      expect(state.errorMessage, isNull);
    });

    test('over http it is refused: nothing sent, nothing stored', () async {
      final store = InMemorySubsonicSessionStore();
      final client = FakeSubsonicClient();
      final container = _container(client: client, store: store);
      final notifier =
          container.read(subsonicSettingsControllerProvider.notifier);
      await _settle();

      final ok = await notifier.signIn(
        url: 'http://192.168.1.20:8080',
        username: 'alice',
        password: 'app-password',
        usePassword: true,
      );

      expect(ok, isFalse);
      expect(client.lastCredentials, isNull);
      expect(await store.read(), isNull);
      final state = container.read(subsonicSettingsControllerProvider);
      expect(state.errorKind, SubsonicErrorKind.cleartextBlocked);
      expect(state.errorMessage, contains('https://'));
      expect(state.usesPassword, isFalse);
    });

    test('a restored password session shows as one', () async {
      final container = _container(
        store: InMemorySubsonicSessionStore(initialSession: passwordSession),
      );
      final notifier =
          container.read(subsonicSettingsControllerProvider.notifier);
      await notifier.ensureLoaded();

      final state = container.read(subsonicSettingsControllerProvider);
      expect(state.isConnected, isTrue);
      expect(state.usesPassword, isTrue);
      expect(notifier.session, passwordSession);
      expect(container.read(subsonicMusicSourceProvider), isNotNull);
    });

    test('sign-out removes the password from the store', () async {
      final store =
          InMemorySubsonicSessionStore(initialSession: passwordSession);
      final container = _container(store: store);
      final notifier =
          container.read(subsonicSettingsControllerProvider.notifier);
      await notifier.ensureLoaded();

      await notifier.clear();

      expect(await store.read(), isNull);
      expect(notifier.session, isNull);
      expect(
        container.read(subsonicSettingsControllerProvider).usesPassword,
        isFalse,
      );
    });

    test('a token sign-in stays a token sign-in', () async {
      final store = InMemorySubsonicSessionStore();
      final container = _container(store: store);
      final notifier =
          container.read(subsonicSettingsControllerProvider.notifier);
      await _settle();

      await notifier.signIn(
        url: 'music.example.com',
        username: 'alice',
        password: 'hunter2',
      );

      expect((await store.read())!.usesPassword, isFalse);
      expect(
        container.read(subsonicSettingsControllerProvider).usesPassword,
        isFalse,
      );
    });
  });

  // Signing out of a password session takes its streams with it: the relay's
  // tokens (and the password URLs behind them) and the warmed URLs pointing
  // at them.
  group('legacy password sign-out and its streams', () {
    const passwordSession = SubsonicSession.password(
      baseUrl: 'https://cloud.example.com',
      username: 'alice',
      password: 'app-password',
    );

    RemoteCacheEntry warmed() {
      final DateTime now = DateTime.now();
      return RemoteCacheEntry(
        key: RemoteCacheKey.forUri('subsonic:s1')!,
        streamUri: Uri.parse('http://127.0.0.1:1/stream/token'),
        source: PlaybackSource.streamingDirect,
        resolvedAt: now,
        expiresAt: now.add(const Duration(minutes: 2)),
      );
    }

    ProviderContainer containerWith(
      SubsonicSession session,
      _RecordingRelay relay,
      RemotePlaybackCache cache,
    ) {
      final container = ProviderContainer(overrides: <Override>[
        subsonicClientProvider.overrideWithValue(FakeSubsonicClient()),
        subsonicSessionStoreProvider.overrideWithValue(
          InMemorySubsonicSessionStore(initialSession: session),
        ),
        subsonicStreamRelayProvider.overrideWithValue(relay),
        remotePlaybackCacheProvider.overrideWithValue(cache),
      ]);
      addTearDown(container.dispose);
      return container;
    }

    test('signing out revokes the relay and drops warmed streams', () async {
      final relay = _RecordingRelay();
      final cache = RemotePlaybackCache()..store(warmed());
      final container = containerWith(passwordSession, relay, cache);
      final notifier =
          container.read(subsonicSettingsControllerProvider.notifier);
      await notifier.ensureLoaded();

      await notifier.clear();

      expect(relay.revoked, 1);
      expect(cache.length, 0);
    });

    test('a password source is built with the relay', () async {
      final relay = _RecordingRelay();
      final container =
          containerWith(passwordSession, relay, RemotePlaybackCache());
      await container
          .read(subsonicSettingsControllerProvider.notifier)
          .ensureLoaded();

      final source = container.read(subsonicMusicSourceProvider)!;
      expect(source.session.usesPassword, isTrue);
      // Proven end to end in subsonic_music_source_test; here, that it is
      // given one at all: a relay-less password source refuses to stream.
      await expectLater(
        source.resolvePlayableUri(
          const Track(id: 's1', title: 'One', uri: 'subsonic:s1'),
        ),
        completion(isNot(isNull)),
      );
      expect(relay.published, 1);
    });

    test('a token sign-out leaves the relay and warmed streams alone',
        () async {
      final relay = _RecordingRelay();
      final cache = RemotePlaybackCache()..store(warmed());
      final container = containerWith(_session, relay, cache);
      final notifier =
          container.read(subsonicSettingsControllerProvider.notifier);
      await notifier.ensureLoaded();

      await notifier.clear();

      expect(relay.revoked, 0);
      expect(cache.length, 1);
    });
  });
}

/// Counts what the controller asks of the relay, without opening a socket.
class _RecordingRelay extends SubsonicStreamRelay {
  _RecordingRelay()
      : super(client: MockClient((_) async => http.Response('', 200)));

  int revoked = 0;
  int published = 0;

  @override
  Future<Uri> publish(Uri upstream, {required int generation}) async {
    published++;
    return Uri.parse('http://127.0.0.1:1/stream/token');
  }

  @override
  Future<void> revokeAll() async => revoked++;
}
