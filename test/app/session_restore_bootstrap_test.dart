import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/application_lifecycle.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/persisted_playback_session.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_session_store.dart';
import 'package:linthra/data/repositories/in_memory_playback_session_store.dart';
import 'package:linthra/data/repositories/jellyfin_session_store_provider.dart';
import 'package:linthra/data/repositories/playback_session_store_provider.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_providers.dart';

import '../core/sources/jellyfin/fake_jellyfin_client.dart';
import '../support/counting_audio_player.dart';
import '../support/fake_local_file_presence.dart';
import '../support/recording_media_session.dart';

/// A home server at a LAN address, launched from somewhere else: its requests
/// get no answer until they time out, the way a blackholed address behaves.
class _SilentServerClient extends FakeJellyfinClient {
  bool asked = false;
  final Completer<void> answer = Completer<void>();

  @override
  Future<void> verifySession(JellyfinSession session) async {
    asked = true;
    await answer.future;
    throw JellyfinException.notReachable();
  }
}

const JellyfinSession _session = JellyfinSession(
  baseUrl: 'http://192.168.22.1:8096',
  userId: 'user-1',
  accessToken: 'tok',
  deviceId: 'device-1',
);

const Track _lastPlayed = Track(
  id: 'item-1',
  title: 'Hello',
  uri: 'jellyfin:item-1',
  duration: Duration(minutes: 3),
);

void main() {
  // Linux brings the last queue back at launch, and `main()` shows the window
  // only once bootstrap has returned. The queue's song is a stream, so putting
  // it back asks its server first.
  testWidgets(
      'launch does not wait out a silent server to restore the last queue',
      (WidgetTester tester) async {
    final _SilentServerClient client = _SilentServerClient();
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        hostPlatformProvider.overrideWithValue(HostPlatform.linux),
        linuxAudioPlayerProvider.overrideWithValue(CountingAudioPlayer()),
        localFilePresenceProvider
            .overrideWithValue(FakeLocalFilePresence.all()),
        playbackSessionStoreProvider.overrideWithValue(
          InMemoryPlaybackSessionStore(
            const PersistedPlaybackSession(
              tracks: <Track>[_lastPlayed],
              currentIndex: 0,
              position: Duration(minutes: 1),
              shuffleEnabled: false,
              repeatMode: RepeatMode.off,
            ),
          ),
        ),
        jellyfinSessionStoreProvider.overrideWithValue(
          InMemoryJellyfinSessionStore(initialSession: _session),
        ),
        jellyfinClientProvider.overrideWithValue(client),
      ],
    );
    addTearDown(container.dispose);

    ApplicationHandle? handle;
    unawaited(
      bootstrapApplication(
        container,
        installPersistentArtworkCache: false,
        mediaSessionBinding:
            RecordingMediaSessionBinding(session: RecordingMediaSession()),
      ).then((ApplicationHandle h) => handle = h),
    );
    await tester.pump();
    expect(client.asked, isTrue,
        reason: 'the restore is waiting on the server');

    // Two seconds, nowhere near the client's 20 second timeout.
    await tester.pump(const Duration(seconds: 2));
    expect(handle, isNotNull,
        reason: 'the window must not stay shut while the server is silent');

    // Meanwhile the last queue is already in place, still being put back.
    expect(
      container.read(playbackControllerProvider).state.currentTrack?.uri,
      _lastPlayed.uri,
    );
  });

  // The window is up while the last queue is still being put back, so the
  // listener can pick something else and quit before the silent server has
  // answered (a request only gives up after the client's 20 second timeout).
  testWidgets(
      'a queue picked while the last one is still being put back is what the '
      'next launch restores', (WidgetTester tester) async {
    final _SilentServerClient client = _SilentServerClient();
    final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore(
      const PersistedPlaybackSession(
        tracks: <Track>[_lastPlayed],
        currentIndex: 0,
        position: Duration(minutes: 1),
        shuffleEnabled: false,
        repeatMode: RepeatMode.off,
      ),
    );
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        hostPlatformProvider.overrideWithValue(HostPlatform.linux),
        linuxAudioPlayerProvider.overrideWithValue(CountingAudioPlayer()),
        localFilePresenceProvider
            .overrideWithValue(FakeLocalFilePresence.all()),
        playbackSessionStoreProvider.overrideWithValue(store),
        jellyfinSessionStoreProvider.overrideWithValue(
          InMemoryJellyfinSessionStore(initialSession: _session),
        ),
        jellyfinClientProvider.overrideWithValue(client),
      ],
    );
    addTearDown(container.dispose);

    ApplicationHandle? handle;
    unawaited(
      bootstrapApplication(
        container,
        installPersistentArtworkCache: false,
        mediaSessionBinding:
            RecordingMediaSessionBinding(session: RecordingMediaSession()),
      ).then((ApplicationHandle h) => handle = h),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(handle, isNotNull);
    expect(client.asked, isTrue,
        reason: 'the restore is still waiting on the server');

    // The listener plays something else from the window, then quits.
    const Track picked =
        Track(id: '/music/b.mp3', title: 'Picked', uri: '/music/b.mp3');
    unawaited(container.read(playbackControllerProvider).playTrack(picked));
    await tester.pump(const Duration(seconds: 1));
    expect(
      container.read(playbackControllerProvider).state.currentTrack?.uri,
      picked.uri,
    );
    unawaited(handle!.shutdown());
    await tester.pump(const Duration(seconds: 1));

    // The server's request only gives up long after the quit.
    client.answer.complete();
    await tester.pump(const Duration(seconds: 1));

    final PersistedPlaybackSession? next = await store.load();
    expect(next?.current?.uri, picked.uri,
        reason: 'the next launch must come back on what was playing at the '
            'quit, not on the queue this launch was still putting back');
  });
}
