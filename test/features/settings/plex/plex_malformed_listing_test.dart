import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/sources/plex/http_plex_client.dart';
import 'package:linthra/core/sources/plex/plex_client.dart';
import 'package:linthra/data/repositories/in_memory_plex_session_store.dart';
import 'package:linthra/data/repositories/plex_session_store_provider.dart';
import 'package:linthra/features/settings/plex/plex_settings_controller.dart';
import 'package:linthra/features/settings/plex/plex_settings_providers.dart';
import 'package:linthra/features/settings/plex/plex_settings_state.dart';

// A library listing whose numbers come back as strings ("size": "1"): a
// response Linthra can't fully use, as #781 found Subsonic servers send.
// Whatever it makes of it, loading the libraries has to end, or the picker
// spins for good with its Refresh button disabled until a restart.

const PlexSession _session = PlexSession(
  baseUrl: 'https://plex.example.com:32400',
  token: 'tok',
  machineIdentifier: 'machine-abc',
  clientIdentifier: 'install-1',
  selectedSectionKeys: <String>['5'],
);

void main() {
  test('a library listing with a number sent as a string still ends loading',
      () async {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        plexSessionStoreProvider.overrideWithValue(
          InMemoryPlexSessionStore(initialSession: _session),
        ),
        plexClientProvider.overrideWithValue(HttpPlexClient(
          identity: const PlexClientIdentity(
            clientIdentifier: 'install-1',
            product: 'Linthra',
            version: '0.0.0',
            platform: 'Linux',
            device: 'Test',
          ),
          httpClient: MockClient((http.Request request) async {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'MediaContainer': <String, dynamic>{
                  'size': '1',
                  'Directory': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'key': '5',
                      'title': 'Music',
                      'type': 'artist',
                    },
                  ],
                },
              }),
              200,
              headers: const <String, String>{
                'content-type': 'application/json',
              },
            );
          }),
        )),
      ],
    );
    addTearDown(container.dispose);
    final PlexSettingsController settings =
        container.read(plexSettingsControllerProvider.notifier);
    await settings.ensureLoaded();
    expect(container.read(plexSettingsControllerProvider).isConnected, isTrue);

    Object? escaped;
    try {
      await settings.refreshSections();
    } catch (error) {
      escaped = error;
    }

    final PlexSettingsState state =
        container.read(plexSettingsControllerProvider);
    expect(escaped, isNull, reason: 'refreshSections must not throw');
    expect(state.isLoadingSections, isFalse,
        reason: 'the library picker must not spin for good');
  });
}
