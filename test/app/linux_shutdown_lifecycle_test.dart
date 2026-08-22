import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/application_lifecycle.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/linux_playback_controller.dart';
import 'package:linthra/data/database/linthra_database.dart';
import 'package:linthra/data/database/linthra_database_provider.dart';
import 'package:linthra/data/repositories/drift_music_library_repository.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_playback_session_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playback_session_store_provider.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/settings/playback/normalize_volume_controller.dart';

import '../support/counting_audio_player.dart';

/// Builds the Linux provider graph the way `main()` wires it, without
/// `runApp`, so shutdown cycles can be exercised deterministically.
Future<ApplicationHandle> _bootstrapLinuxTestGraph({
  required ProviderContainer container,
}) {
  return bootstrapApplication(
    container,
    installPersistentArtworkCache: false,
  );
}

List<Override> _linuxTestOverrides({
  required CountingAudioPlayer audioPlayer,
  required LinthraDatabase database,
}) {
  return <Override>[
    hostPlatformProvider.overrideWithValue(HostPlatform.linux),
    linuxAudioPlayerProvider.overrideWithValue(audioPlayer),
    linthraDatabaseProvider.overrideWithValue(database),
    driftMusicLibraryRepositoryOverride,
    playbackSessionStoreProvider
        .overrideWithValue(InMemoryPlaybackSessionStore()),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Linux shutdown lifecycle', () {
    test('initialize -> play -> stop -> shutdown -> initialize again',
        () async {
      final CountingAudioPlayer firstPlayer = CountingAudioPlayer();
      final LinthraDatabase firstDb =
          LinthraDatabase.forTesting(NativeDatabase.memory());
      final ProviderContainer firstContainer = ProviderContainer(
        overrides: _linuxTestOverrides(
          audioPlayer: firstPlayer,
          database: firstDb,
        ),
      );

      final ApplicationHandle firstHandle =
          await _bootstrapLinuxTestGraph(container: firstContainer);

      await firstContainer.read(playbackControllerProvider).playTrack(
            const Track(id: 'a', title: 'Song', uri: '/music/a.mp3'),
          );
      expect(
        firstContainer.read(playbackControllerProvider).state.status,
        PlaybackStatus.playing,
      );

      await firstContainer.read(playbackControllerProvider).stop();
      await firstHandle.shutdown();

      expect(firstPlayer.disposeCount, 1);
      expect(firstPlayer.stopCount, greaterThanOrEqualTo(1));

      final CountingAudioPlayer secondPlayer = CountingAudioPlayer();
      final LinthraDatabase secondDb =
          LinthraDatabase.forTesting(NativeDatabase.memory());
      final ProviderContainer secondContainer = ProviderContainer(
        overrides: _linuxTestOverrides(
          audioPlayer: secondPlayer,
          database: secondDb,
        ),
      );

      final ApplicationHandle secondHandle =
          await _bootstrapLinuxTestGraph(container: secondContainer);

      expect(
        secondContainer.read(localPlaybackControllerProvider),
        isA<LinuxPlaybackController>(),
      );
      await secondContainer.read(playbackControllerProvider).playTrack(
            const Track(id: 'b', title: 'Again', uri: '/music/b.mp3'),
          );
      expect(
        secondContainer.read(playbackControllerProvider).state.status,
        PlaybackStatus.playing,
      );

      await secondHandle.shutdown();
      expect(secondPlayer.disposeCount, 1);
    });

    test('initialize -> shutdown without playback', () async {
      final CountingAudioPlayer player = CountingAudioPlayer();
      final LinthraDatabase db =
          LinthraDatabase.forTesting(NativeDatabase.memory());
      final ProviderContainer container = ProviderContainer(
        overrides: _linuxTestOverrides(audioPlayer: player, database: db),
      );

      final ApplicationHandle handle =
          await _bootstrapLinuxTestGraph(container: container);

      await handle.shutdown();

      expect(player.disposeCount, 1);
      expect(player.playCount, 0);
    });

    test('partial startup -> shutdown', () async {
      final CountingAudioPlayer player = CountingAudioPlayer();
      final LinthraDatabase db =
          LinthraDatabase.forTesting(NativeDatabase.memory());
      final ProviderContainer container = ProviderContainer(
        overrides: _linuxTestOverrides(audioPlayer: player, database: db),
      );

      // Read only the early startup surface — not the full bootstrap graph.
      container.read(musicLibraryRepositoryProvider);
      container.read(playbackControllerProvider);

      final ApplicationHandle handle = ApplicationHandle(
        container: container,
        normalizeVolumeSubscription: container.listen(
          normalizeVolumeControllerProvider,
          (_, __) {},
        ),
      );

      await handle.shutdown();

      expect(player.disposeCount, 1);
    });

    test('repeated shutdown is safe', () async {
      final CountingAudioPlayer player = CountingAudioPlayer();
      final LinthraDatabase db =
          LinthraDatabase.forTesting(NativeDatabase.memory());
      final ProviderContainer container = ProviderContainer(
        overrides: _linuxTestOverrides(audioPlayer: player, database: db),
      );

      final ApplicationHandle handle =
          await _bootstrapLinuxTestGraph(container: container);

      await handle.shutdown();
      await handle.shutdown();
      await handle.shutdown();

      expect(player.disposeCount, 1);
    });

    test('database can be recreated after the first container is disposed',
        () async {
      final CountingAudioPlayer player = CountingAudioPlayer();
      final LinthraDatabase db =
          LinthraDatabase.forTesting(NativeDatabase.memory());
      final ProviderContainer container = ProviderContainer(
        overrides: _linuxTestOverrides(audioPlayer: player, database: db),
      );

      final ApplicationHandle handle =
          await _bootstrapLinuxTestGraph(container: container);
      await handle.shutdown();

      final LinthraDatabase freshDb =
          LinthraDatabase.forTesting(NativeDatabase.memory());
      addTearDown(freshDb.close);
      final ProviderContainer freshContainer = ProviderContainer(
        overrides: _linuxTestOverrides(
          audioPlayer: CountingAudioPlayer(),
          database: freshDb,
        ),
      );
      addTearDown(freshContainer.dispose);

      expect(
        freshContainer.read(musicLibraryRepositoryProvider),
        isA<DriftMusicLibraryRepository>(),
      );
    });
  });
}
