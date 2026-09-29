import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/application_lifecycle.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/sources/subsonic/subsonic_account_fingerprint.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_session_store.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_sync_pending_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/subsonic_session_store_provider.dart';
import 'package:linthra/data/repositories/subsonic_sync_pending_store_provider.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_providers.dart';

import '../core/sources/subsonic/synthetic_navidrome.dart';
import '../support/counting_audio_player.dart';
import '../support/lifecycle_test_graph.dart';
import '../support/recording_media_session.dart';

const SubsonicSession _alice = SubsonicSession(
  baseUrl: 'https://music.example.com',
  username: 'alice',
  salt: 'salt',
  token: 'token',
);

/// #680: a Navidrome sync that Android killed partway must pick up again on
/// the next launch, not wait for the user to find the Sync button. This walks
/// the real `bootstrapApplication` graph (with the real Drift repository), so
/// it only passes if bootstrap actually wires the resume.
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  // Bootstrap asks path_provider for the app-support directory; answer with a
  // temporary one so the suite never touches a real user directory.
  setUp(() {
    final Directory temp =
        Directory.systemTemp.createTempSync('linthra-subsonic-bootstrap');
    addTearDown(() => temp.deleteSync(recursive: true));
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => temp.path,
    );
    addTearDown(
      () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      ),
    );
  });

  Future<ProviderContainer> launch({
    required SyntheticNavidrome server,
    required InMemorySubsonicSyncPendingStore pending,
  }) async {
    final ProviderContainer container = ProviderContainer(
      overrides: linuxLifecycleOverrides(
        audioPlayer: CountingAudioPlayer(),
        extra: <Override>[
          subsonicClientProvider.overrideWithValue(server.client()),
          subsonicSessionStoreProvider.overrideWithValue(
            InMemorySubsonicSessionStore(initialSession: _alice),
          ),
          subsonicSyncPendingStoreProvider.overrideWithValue(pending),
        ],
      ),
    );
    addTearDown(container.dispose);
    final ApplicationHandle handle = await bootstrapApplication(
      container,
      mediaSessionBinding:
          RecordingMediaSessionBinding(session: RecordingMediaSession()),
    );
    addTearDown(handle.shutdown);
    return container;
  }

  test('launch resumes an unfinished Subsonic sync for the restored account',
      () async {
    final SyntheticNavidrome server = SyntheticNavidrome(albums: 20);
    final InMemorySubsonicSyncPendingStore pending =
        InMemorySubsonicSyncPendingStore(subsonicAccountFingerprint(_alice));

    final ProviderContainer container =
        await launch(server: server, pending: pending);

    // The resume is fire-and-forget; wait for it to land.
    for (int i = 0; i < 200 && await pending.read() != null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await pending.read(), isNull);
    expect(server.albumCalls, 20);
    final int stored =
        (await container.read(musicLibraryRepositoryProvider).getAllTracks())
            .where((t) => t.uri.startsWith('subsonic:'))
            .length;
    expect(stored, server.trackCount);
  });

  test('launch syncs nothing when no Subsonic sync is unfinished', () async {
    final SyntheticNavidrome server = SyntheticNavidrome(albums: 20);

    await launch(server: server, pending: InMemorySubsonicSyncPendingStore());
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(server.albumListCalls, 0);
    expect(server.albumCalls, 0);
  });
}
