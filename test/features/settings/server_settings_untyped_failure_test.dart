import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/sources/audiobookshelf/http_audiobookshelf_client.dart';
import 'package:linthra/core/sources/jellyfin/http_jellyfin_client.dart';
import 'package:linthra/core/sources/plex/http_plex_client.dart';
import 'package:linthra/core/sources/plex/plex_client.dart';
import 'package:linthra/core/sources/subsonic/http_subsonic_client.dart';
import 'package:linthra/data/repositories/audiobookshelf_session_store_provider.dart';
import 'package:linthra/data/repositories/in_memory_audiobookshelf_session_store.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_session_store.dart';
import 'package:linthra/data/repositories/in_memory_plex_session_store.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_session_store.dart';
import 'package:linthra/data/repositories/jellyfin_session_store_provider.dart';
import 'package:linthra/data/repositories/plex_session_store_provider.dart';
import 'package:linthra/data/repositories/subsonic_session_store_provider.dart';
import 'package:linthra/features/settings/audiobookshelf/audiobookshelf_settings_controller.dart';
import 'package:linthra/features/settings/audiobookshelf/audiobookshelf_settings_providers.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_providers.dart';
import 'package:linthra/features/settings/plex/plex_settings_controller.dart';
import 'package:linthra/features/settings/plex/plex_settings_providers.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_controller.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_providers.dart';

// A server address with a port no server can listen on (`:80966`, a typo
// for 8096) parsed fine, then dart:io refused to connect with an
// ArgumentError. Every provider's HTTP client only turns an `Exception` into
// its typed error, and every settings controller only catches its typed
// error, so the test or sign-in never ended: the card stayed on its spinner,
// every button disabled, until the app was restarted. These run the real
// controller, authenticator and HTTP client of each provider; only the
// network under the client is replaced.

const String _portTypo = 'https://music.example.com:80966';
const String _address = 'https://music.example.com';

/// The HTTP layer as dart:io behaves for a request it refuses before any
/// network I/O: an [ArgumentError], which `package:http` lets through.
class _RefusingNetwork {
  int requests = 0;

  late final MockClient client = MockClient((http.Request request) async {
    requests++;
    throw ArgumentError('Invalid port');
  });
}

const PlexClientIdentity _plexIdentity = PlexClientIdentity(
  clientIdentifier: 'install-1',
  product: 'Linthra',
  version: '0.0.0',
  platform: 'Linux',
  device: 'Test',
);

void main() {
  late _RefusingNetwork network;

  setUp(() => network = _RefusingNetwork());

  ProviderContainer container(List<Override> overrides) {
    final ProviderContainer container = ProviderContainer(overrides: overrides);
    addTearDown(container.dispose);
    return container;
  }

  group('Jellyfin', () {
    late ProviderContainer app;
    late JellyfinSettingsController jellyfin;

    setUp(() {
      app = container(<Override>[
        jellyfinClientProvider
            .overrideWithValue(HttpJellyfinClient(httpClient: network.client)),
        jellyfinSessionStoreProvider
            .overrideWithValue(InMemoryJellyfinSessionStore()),
      ]);
      jellyfin = app.read(jellyfinSettingsControllerProvider.notifier);
    });

    test('a port typo is refused before any request, with the reason',
        () async {
      expect(await jellyfin.testConnection(_portTypo), isFalse);
      expect(
          await jellyfin.signIn(url: _portTypo, username: 'a', password: 'p'),
          isFalse);

      expect(network.requests, 0);
      final state = app.read(jellyfinSettingsControllerProvider);
      expect(state.isBusy, isFalse);
      expect(state.errorMessage, contains('65535'));
    });

    test('an untyped failure still ends the test and the sign-in', () async {
      expect(await jellyfin.testConnection(_address), isFalse);
      expect(app.read(jellyfinSettingsControllerProvider).isBusy, isFalse);

      expect(await jellyfin.signIn(url: _address, username: 'a', password: 'p'),
          isFalse);
      final state = app.read(jellyfinSettingsControllerProvider);
      expect(state.isBusy, isFalse);
      expect(state.errorMessage, isNotNull);
      expect(network.requests, greaterThan(0));
    });
  });

  group('Subsonic', () {
    late ProviderContainer app;
    late SubsonicSettingsController subsonic;

    setUp(() {
      app = container(<Override>[
        subsonicClientProvider
            .overrideWithValue(HttpSubsonicClient(httpClient: network.client)),
        subsonicSessionStoreProvider
            .overrideWithValue(InMemorySubsonicSessionStore()),
      ]);
      subsonic = app.read(subsonicSettingsControllerProvider.notifier);
    });

    test('a port typo is refused before any request, with the reason',
        () async {
      expect(
          await subsonic.testConnection(
              url: _portTypo, username: 'a', password: 'p'),
          isFalse);
      expect(
          await subsonic.signIn(url: _portTypo, username: 'a', password: 'p'),
          isFalse);

      expect(network.requests, 0);
      final state = app.read(subsonicSettingsControllerProvider);
      expect(state.isBusy, isFalse);
      expect(state.errorMessage, contains('65535'));
    });

    test('an untyped failure still ends the test and the sign-in', () async {
      expect(
          await subsonic.testConnection(
              url: _address, username: 'a', password: 'p'),
          isFalse);
      expect(app.read(subsonicSettingsControllerProvider).isBusy, isFalse);

      expect(await subsonic.signIn(url: _address, username: 'a', password: 'p'),
          isFalse);
      final state = app.read(subsonicSettingsControllerProvider);
      expect(state.isBusy, isFalse);
      expect(state.errorMessage, isNotNull);
      expect(network.requests, greaterThan(0));
    });
  });

  group('Plex', () {
    late ProviderContainer app;
    late PlexSettingsController plex;

    setUp(() {
      app = container(<Override>[
        plexClientProvider.overrideWithValue(HttpPlexClient(
            identity: _plexIdentity, httpClient: network.client)),
        plexSessionStoreProvider.overrideWithValue(InMemoryPlexSessionStore()),
      ]);
      plex = app.read(plexSettingsControllerProvider.notifier);
    });

    test('a port typo is refused before any request, with the reason',
        () async {
      expect(await plex.testConnection(url: _portTypo, token: 't'), isFalse);
      expect(await plex.connect(url: _portTypo, token: 't'), isFalse);

      expect(network.requests, 0);
      final state = app.read(plexSettingsControllerProvider);
      expect(state.isBusy, isFalse);
      expect(state.errorMessage, contains('65535'));
    });

    test('an untyped failure still ends the test and the connect', () async {
      expect(await plex.testConnection(url: _address, token: 't'), isFalse);
      expect(app.read(plexSettingsControllerProvider).isBusy, isFalse);

      expect(await plex.connect(url: _address, token: 't'), isFalse);
      final state = app.read(plexSettingsControllerProvider);
      expect(state.isBusy, isFalse);
      expect(state.errorMessage, isNotNull);
      expect(network.requests, greaterThan(0));
    });
  });

  group('Audiobookshelf', () {
    late ProviderContainer app;
    late AudiobookshelfSettingsController audiobookshelf;

    setUp(() {
      app = container(<Override>[
        audiobookshelfClientProvider.overrideWithValue(
            HttpAudiobookshelfClient(httpClient: network.client)),
        audiobookshelfSessionStoreProvider
            .overrideWithValue(InMemoryAudiobookshelfSessionStore()),
      ]);
      audiobookshelf =
          app.read(audiobookshelfSettingsControllerProvider.notifier);
    });

    test('a port typo is refused before any request, with the reason',
        () async {
      expect(await audiobookshelf.testConnection(_portTypo), isFalse);
      expect(
          await audiobookshelf.signIn(
              url: _portTypo, username: 'a', password: 'p'),
          isFalse);

      expect(network.requests, 0);
      final state = app.read(audiobookshelfSettingsControllerProvider);
      expect(state.isBusy, isFalse);
      expect(state.errorMessage, contains('65535'));
    });

    test('an untyped failure still ends the test and the sign-in', () async {
      expect(await audiobookshelf.testConnection(_address), isFalse);
      expect(
          app.read(audiobookshelfSettingsControllerProvider).isBusy, isFalse);

      expect(
          await audiobookshelf.signIn(
              url: _address, username: 'a', password: 'p'),
          isFalse);
      final state = app.read(audiobookshelfSettingsControllerProvider);
      expect(state.isBusy, isFalse);
      expect(state.errorMessage, isNotNull);
      expect(network.requests, greaterThan(0));
    });
  });
}
