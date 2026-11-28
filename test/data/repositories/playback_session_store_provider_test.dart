import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/application_container.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/theme_mode_preference.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/playback_session_persistence.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_playback_session_store.dart';
import 'package:linthra/data/repositories/playback_session_store_provider.dart';
import 'package:linthra/data/repositories/shared_preferences_playback_session_store.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/player/fake_playback_controller.dart';
import '../../support/fake_audio_player.dart';

/// Android documents, as the SAF scan names local tracks.
Track _song(int n) => Track(
      id: 'content://com.android.externalstorage.documents/document/'
          'primary%3AMusic%2F$n.flac',
      title: 'Song $n',
      uri: 'content://com.android.externalstorage.documents/document/'
          'primary%3AMusic%2F$n.flac',
      duration: const Duration(minutes: 4),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the queue is kept on Linux and Android, nowhere else', () {
    final ProviderContainer linux = ProviderContainer(
      overrides: <Override>[
        hostPlatformProvider.overrideWithValue(HostPlatform.linux),
        linuxAudioPlayerProvider.overrideWithValue(FakeAudioPlayer()),
      ],
    );
    addTearDown(linux.dispose);
    expect(linux.read(playbackSessionPersistenceProvider), isNotNull);

    final ProviderContainer android = ProviderContainer(
      overrides: <Override>[
        hostPlatformProvider.overrideWithValue(HostPlatform.android),
        localPlaybackControllerProvider
            .overrideWithValue(FakePlaybackController()),
      ],
    );
    addTearDown(android.dispose);
    expect(android.read(playbackSessionPersistenceProvider), isNotNull);

    final ProviderContainer ios = ProviderContainer(
      overrides: <Override>[
        hostPlatformProvider.overrideWithValue(HostPlatform.ios),
      ],
    );
    addTearDown(ios.dispose);
    expect(ios.read(playbackSessionPersistenceProvider), isNull);
  });

  test('production keeps it on disk on Linux and Android', () {
    ProviderContainer production(HostPlatform host) {
      final ProviderContainer c = ProviderContainer(
        overrides: productionApplicationOverrides(
          storedThemeMode: ThemeModePreference.system,
          host: host,
        ),
      );
      addTearDown(c.dispose);
      return c;
    }

    expect(
      production(HostPlatform.linux).read(playbackSessionStoreProvider),
      isA<SharedPreferencesPlaybackSessionStore>(),
    );
    expect(
      production(HostPlatform.android).read(playbackSessionStoreProvider),
      isA<SharedPreferencesPlaybackSessionStore>(),
    );
    expect(
      production(HostPlatform.ios).read(playbackSessionStoreProvider),
      isA<InMemoryPlaybackSessionStore>(),
    );
  });

  test(
      '#1005: a queue paused on Android comes back, where it was, '
      'after the app is closed', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    // First run: a queue plays, is paused 1:23 into its second song, and the
    // app is closed. Android then ends the process: nothing gets to run, so
    // only what the pause saved is left (no dispose, no shutdown).
    final FakePlaybackController before = FakePlaybackController();
    final ProviderContainer first = ProviderContainer(
      overrides: <Override>[
        hostPlatformProvider.overrideWithValue(HostPlatform.android),
        playbackSessionStoreProvider
            .overrideWithValue(const SharedPreferencesPlaybackSessionStore()),
        localPlaybackControllerProvider.overrideWithValue(before),
      ],
    );
    expect(first.read(playbackSessionPersistenceProvider), isNotNull);
    await before
        .playTracks(<Track>[_song(1), _song(2), _song(3)], startIndex: 1);
    await pumpEventQueue();
    before.emit(before.state.copyWith(
      status: PlaybackStatus.paused,
      position: const Duration(minutes: 1, seconds: 23),
    ));
    await pumpEventQueue();

    // Next launch, a new process.
    final FakePlaybackController after = FakePlaybackController();
    final ProviderContainer second = ProviderContainer(
      overrides: <Override>[
        hostPlatformProvider.overrideWithValue(HostPlatform.android),
        playbackSessionStoreProvider
            .overrideWithValue(const SharedPreferencesPlaybackSessionStore()),
        localPlaybackControllerProvider.overrideWithValue(after),
      ],
    );
    addTearDown(second.dispose);
    final PlaybackSessionPersistence restore =
        second.read(playbackSessionPersistenceProvider)!;
    await restore.restore();

    expect(after.restoreSessionCount, 1);
    expect(after.lastRestoreAutoplay, isFalse);
    expect(after.lastRestorePosition, const Duration(minutes: 1, seconds: 23));
    expect(after.state.currentTrack?.uri, _song(2).uri);
    expect(
      after.state.previous.map((Track t) => t.uri),
      <String>[_song(1).uri],
    );
    expect(
      after.state.upNext.map((Track t) => t.uri),
      <String>[_song(3).uri],
    );
  });
}
