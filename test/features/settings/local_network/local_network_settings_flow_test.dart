import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/services/local_network/local_network_permission.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_session_store.dart';
import 'package:linthra/data/repositories/jellyfin_session_store_provider.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_providers.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_state.dart';
import 'package:linthra/features/settings/local_network/local_network_providers.dart';

import '../../../core/sources/jellyfin/fake_jellyfin_client.dart';
import '../jellyfin/fake_jellyfin_authenticator.dart';

/// Android's answers, scripted: [current] is what a status read returns and
/// every request moves it to the next of [answers].
class _ScriptedPermission implements LocalNetworkPermission {
  _ScriptedPermission(this.current, [List<LocalNetworkPermissionStatus>? next])
      : answers = next ?? <LocalNetworkPermissionStatus>[];

  LocalNetworkPermissionStatus current;
  final List<LocalNetworkPermissionStatus> answers;
  int requests = 0;
  int settingsOpened = 0;

  @override
  Future<LocalNetworkPermissionStatus> status() async => current;

  @override
  Future<LocalNetworkPermissionStatus> request() async {
    requests++;
    if (answers.isNotEmpty) current = answers.removeAt(0);
    return current;
  }

  @override
  Future<void> openAppSettings() async => settingsOpened++;
}

const String _lanUrl = 'http://192.168.1.20:8096';

({ProviderContainer container, FakeJellyfinAuthenticator auth}) _setUp(
  _ScriptedPermission permission,
) {
  final FakeJellyfinAuthenticator auth = FakeJellyfinAuthenticator();
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      jellyfinAuthenticatorProvider.overrideWithValue(auth),
      jellyfinSessionStoreProvider
          .overrideWithValue(InMemoryJellyfinSessionStore()),
      jellyfinClientProvider.overrideWithValue(FakeJellyfinClient()),
      localNetworkPermissionProvider.overrideWithValue(permission),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, auth: auth);
}

void main() {
  group('Test connection to a LAN server on Android 17', () {
    test('asks first; a refusal explains itself and nothing is sent', () async {
      final _ScriptedPermission permission = _ScriptedPermission(
        LocalNetworkPermissionStatus.notRequested,
        <LocalNetworkPermissionStatus>[LocalNetworkPermissionStatus.denied],
      );
      final (:ProviderContainer container, :FakeJellyfinAuthenticator auth) =
          _setUp(permission);

      final bool ok = await container
          .read(jellyfinSettingsControllerProvider.notifier)
          .testConnection(_lanUrl);

      expect(ok, isFalse);
      expect(permission.requests, 1);
      expect(auth.lastTestUrl, isNull,
          reason: 'a request Android would block is never attempted');
      final JellyfinSettingsState state =
          container.read(jellyfinSettingsControllerProvider);
      expect(state.errorMessage, contains('local network'));
      expect(state.errorMessage, isNot(contains('192.168')),
          reason: 'the message never repeats the address back');
      expect(state.errorKind, JellyfinErrorKind.notReachable);
    });

    test('a grant lets the test go through straight away', () async {
      final _ScriptedPermission permission = _ScriptedPermission(
        LocalNetworkPermissionStatus.denied,
        <LocalNetworkPermissionStatus>[LocalNetworkPermissionStatus.granted],
      );
      final (:ProviderContainer container, :FakeJellyfinAuthenticator auth) =
          _setUp(permission);
      int grants = 0;
      container.listen<int>(localNetworkGrantsProvider, (_, __) => grants++);

      final bool ok = await container
          .read(jellyfinSettingsControllerProvider.notifier)
          .testConnection(_lanUrl);

      expect(ok, isTrue);
      expect(auth.lastTestUrl, _lanUrl);
      expect(grants, 1);
    });

    test('a permanent refusal is not re-asked; it points at settings',
        () async {
      final _ScriptedPermission permission =
          _ScriptedPermission(LocalNetworkPermissionStatus.permanentlyDenied);
      final (:ProviderContainer container, :FakeJellyfinAuthenticator auth) =
          _setUp(permission);

      final bool ok = await container
          .read(jellyfinSettingsControllerProvider.notifier)
          .signIn(url: _lanUrl, username: 'alice', password: 'pw');

      expect(ok, isFalse);
      expect(permission.requests, 0);
      expect(auth.lastSignInUrl, isNull);
      expect(container.read(jellyfinSettingsControllerProvider).errorMessage,
          contains('Nearby devices'));
    });

    test('an address typed without a scheme is still recognised', () async {
      final _ScriptedPermission permission =
          _ScriptedPermission(LocalNetworkPermissionStatus.permanentlyDenied);
      final (:ProviderContainer container, :FakeJellyfinAuthenticator auth) =
          _setUp(permission);

      await container
          .read(jellyfinSettingsControllerProvider.notifier)
          .testConnection('192.168.1.20:8096');

      expect(auth.lastTestUrl, isNull);
    });

    test('an internet server never involves the permission', () async {
      final _ScriptedPermission permission =
          _ScriptedPermission(LocalNetworkPermissionStatus.permanentlyDenied);
      final (:ProviderContainer container, :FakeJellyfinAuthenticator auth) =
          _setUp(permission);

      final bool ok = await container
          .read(jellyfinSettingsControllerProvider.notifier)
          .testConnection('https://203.0.113.7');

      expect(ok, isTrue);
      expect(auth.lastTestUrl, 'https://203.0.113.7');
      expect(permission.requests, 0);
    });

    test('before Android 17 nothing changes', () async {
      final _ScriptedPermission permission =
          _ScriptedPermission(LocalNetworkPermissionStatus.notRequired);
      final (:ProviderContainer container, :FakeJellyfinAuthenticator auth) =
          _setUp(permission);

      expect(
          await container
              .read(jellyfinSettingsControllerProvider.notifier)
              .testConnection(_lanUrl),
          isTrue);
      expect(permission.requests, 0);
    });
  });

  group('the Connections card', () {
    test('shows only while a configured LAN server lacks access', () async {
      final _ScriptedPermission permission = _ScriptedPermission(
        LocalNetworkPermissionStatus.granted,
        <LocalNetworkPermissionStatus>[LocalNetworkPermissionStatus.granted],
      );
      final FakeJellyfinAuthenticator auth = FakeJellyfinAuthenticator(
        session: const JellyfinSession(
          baseUrl: _lanUrl,
          userId: 'user-1',
          accessToken: 'tok',
          deviceId: 'device-1',
          userName: 'alice',
        ),
      );
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          jellyfinAuthenticatorProvider.overrideWithValue(auth),
          jellyfinSessionStoreProvider
              .overrideWithValue(InMemoryJellyfinSessionStore()),
          jellyfinClientProvider.overrideWithValue(FakeJellyfinClient()),
          localNetworkPermissionProvider.overrideWithValue(permission),
        ],
      );
      addTearDown(container.dispose);
      container.listen(localNetworkAccessNeededProvider, (_, __) {});

      expect(
          await container.read(localNetworkAccessNeededProvider.future), isNull,
          reason: 'nothing configured yet');

      await container
          .read(jellyfinSettingsControllerProvider.notifier)
          .signIn(url: _lanUrl, username: 'alice', password: 'pw');
      expect(
          await container.read(localNetworkAccessNeededProvider.future), isNull,
          reason: 'granted: nothing to offer');

      // Revoked in Android settings while Linthra was in the background.
      permission.current = LocalNetworkPermissionStatus.denied;
      container.read(localNetworkAccessProvider).onAppShown();
      container.invalidate(localNetworkAccessNeededProvider);
      expect(await container.read(localNetworkAccessNeededProvider.future),
          LocalNetworkPermissionStatus.denied);

      // The card's Allow button.
      await container.read(localNetworkAccessProvider).request();
      expect(
          await container.read(localNetworkAccessNeededProvider.future), isNull,
          reason: 'a grant hides the card on its own');
    });
  });
}
