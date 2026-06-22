import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/music_library_repository.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_auto_sync_store.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_session_store.dart';
import 'package:linthra/data/repositories/jellyfin_auto_sync_store_provider.dart';
import 'package:linthra/data/repositories/jellyfin_session_store_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_providers.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_section.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_sync_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_sync_state.dart';

import '../../../core/sources/jellyfin/fake_jellyfin_client.dart';
import 'fake_jellyfin_authenticator.dart';

const _session = JellyfinSession(
  baseUrl: 'https://music.example.com',
  userId: 'user-1',
  accessToken: 'secret-token',
  deviceId: 'device-1',
  userName: 'alice',
  serverName: 'Home',
);

/// Holds the sync controller in a fixed state so the connected-view rendering
/// can be asserted without driving (and timing) a real sync.
class _FixedSyncController extends JellyfinSyncController {
  _FixedSyncController(this._fixed);
  final JellyfinSyncState _fixed;
  @override
  JellyfinSyncState build() => _fixed;
}

/// A recording repo that counts upserts, so the "reopen doesn't resync" test can
/// prove sign-in synced exactly once across a screen close + reopen.
class _RecordingRepository implements MusicLibraryRepository {
  int upsertCount = 0;
  List<Track> _tracks = const <Track>[];

  @override
  Future<void> upsertCatalog({
    required String sourceId,
    required List<Track> tracks,
    required List<Album> albums,
    required List<Artist> artists,
  }) async {
    upsertCount++;
    _tracks = tracks;
  }

  @override
  Future<List<Track>> getAllTracks() async => _tracks;
  @override
  Future<List<Album>> getAllAlbums() async => const <Album>[];
  @override
  Future<List<Artist>> getAllArtists() async => const <Artist>[];
  @override
  Future<Track?> getTrackByUri(String uri) async => null;
  @override
  Future<void> removeTracks(List<String> trackIds) async {}
}

Future<void> _pumpConnected(
  WidgetTester tester,
  JellyfinSyncState syncState,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        jellyfinAuthenticatorProvider
            .overrideWithValue(FakeJellyfinAuthenticator()),
        jellyfinSessionStoreProvider.overrideWithValue(
          InMemoryJellyfinSessionStore(initialSession: _session),
        ),
        jellyfinClientProvider.overrideWithValue(FakeJellyfinClient()),
        jellyfinSyncControllerProvider
            .overrideWith(() => _FixedSyncController(syncState)),
      ],
      child: const MaterialApp(
        home: Scaffold(body: JellyfinSettingsSection()),
      ),
    ),
  );
  // Let the controller's persisted-session load settle into the connected view.
  // Avoid pumpAndSettle: a syncing state shows an endless spinner.
  await tester.pump();
  await tester.pump();
}

void main() {
  group('connected-view sync states', () {
    testWidgets('shows a friendly syncing line while a sync runs',
        (tester) async {
      await _pumpConnected(tester, const JellyfinSyncState.syncing());

      expect(find.text('Syncing…'), findsOneWidget);
      expect(
          find.textContaining('Syncing your Jellyfin library'), findsOneWidget);
      // No retry while it's still going.
      expect(find.text('Retry sync'), findsNothing);
    });

    testWidgets('shows the success summary when a sync lands', (tester) async {
      await _pumpConnected(
        tester,
        const JellyfinSyncState.success(
          trackCount: 12,
          message: 'Synced 12 tracks from your Jellyfin library.',
        ),
      );

      expect(find.textContaining('Synced 12 tracks'), findsOneWidget);
      expect(find.text('Retry sync'), findsNothing);
    });

    testWidgets('shows a friendly failure with a Retry action', (tester) async {
      await _pumpConnected(
        tester,
        const JellyfinSyncState.error(
          "Couldn't reach your Jellyfin server. Check your connection.",
        ),
      );

      // Connection is intact, the failure is framed gently, and Retry is there.
      expect(find.textContaining("didn't finish"), findsOneWidget);
      expect(find.textContaining("Couldn't reach"), findsOneWidget);
      expect(find.text('Retry sync'), findsOneWidget);
      // Sign-out is still offered; the user isn't stuck.
      expect(find.text('Sign out & clear'), findsOneWidget);
    });
  });

  group('reopening the settings screen', () {
    testWidgets('does not start a second sync', (tester) async {
      final repo = _RecordingRepository();
      final container = ProviderContainer(overrides: <Override>[
        jellyfinAuthenticatorProvider
            .overrideWithValue(FakeJellyfinAuthenticator(session: _session)),
        jellyfinSessionStoreProvider
            .overrideWithValue(InMemoryJellyfinSessionStore()),
        jellyfinClientProvider.overrideWithValue(
          FakeJellyfinClient(
            itemsByKind: <JellyfinItemKind, List<JellyfinItemDto>>{
              JellyfinItemKind.audio: <JellyfinItemDto>[
                const JellyfinItemDto(id: 'a', name: 'A'),
              ],
            },
          ),
        ),
        jellyfinAutoSyncStoreProvider
            .overrideWithValue(InMemoryJellyfinAutoSyncStore()),
        musicLibraryRepositoryProvider.overrideWithValue(repo),
      ]);
      addTearDown(container.dispose);

      Widget section() => UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              home: Scaffold(body: JellyfinSettingsSection()),
            ),
          );

      // Open Settings and sign in.
      await tester.pumpWidget(section());
      await tester.pump();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'music.example.com');
      await tester.enterText(fields.at(1), 'alice');
      await tester.enterText(fields.at(2), 'pw');
      await tester.pump();
      await tester.tap(find.text('Sign in'));
      // Let sign-in connect and the fire-and-forget auto-sync finish.
      for (int i = 0; i < 12; i++) {
        await tester.pump();
      }
      expect(repo.upsertCount, 1);

      // Close Settings, then reopen it (same container, as the app would).
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(section());
      for (int i = 0; i < 12; i++) {
        await tester.pump();
      }

      // Reopening rebuilt the widget but must not re-trigger the sync.
      expect(repo.upsertCount, 1);
      expect(find.text('Sign out & clear'), findsOneWidget);
    });
  });
}
