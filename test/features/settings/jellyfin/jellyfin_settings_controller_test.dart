import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_session_store.dart';
import 'package:linthra/data/repositories/jellyfin_session_store_provider.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_providers.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_state.dart';

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

ProviderContainer _container({
  FakeJellyfinAuthenticator? authenticator,
  InMemoryJellyfinSessionStore? store,
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

      expect(auth.lastServerName, 'My Server');
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
}
