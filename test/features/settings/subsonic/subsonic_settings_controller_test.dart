import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_index.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_record.dart';
import 'package:linthra/core/sources/subsonic/subsonic_exception.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_session_store.dart';
import 'package:linthra/data/repositories/remote_cache_index_provider.dart';
import 'package:linthra/data/repositories/subsonic_session_store_provider.dart';
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

ProviderContainer _container({
  FakeSubsonicClient? client,
  InMemorySubsonicSessionStore? store,
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
}
