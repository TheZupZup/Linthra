import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_providers.dart';

import '../../core/sources/jellyfin/fake_jellyfin_client.dart';
import 'fake_playback_controller.dart';

// Signing out never stops playback. This runs the real reporting service and
// reporters with the real Jellyfin sign-in and sign-out, and lets the queue
// move to the next song while nobody is signed in, the way a pre-cached or
// downloaded song keeps playing after a sign-out.

const Track _first = Track(
  id: 'item-1',
  title: 'First',
  uri: 'jellyfin:item-1',
  duration: Duration(minutes: 3),
);
const Track _second = Track(
  id: 'item-2',
  title: 'Second',
  uri: 'jellyfin:item-2',
  duration: Duration(minutes: 3),
);
const Track _third = Track(
  id: 'item-3',
  title: 'Third',
  uri: 'jellyfin:item-3',
  duration: Duration(minutes: 3),
);

void main() {
  test(
      'a song that started while signed out is not reported to the account '
      'that signs in during it', () async {
    final FakeJellyfinClient client = FakeJellyfinClient(
      serverInfo: const JellyfinServerInfo(
        serverName: 'Family server',
        version: '10.9.11',
      ),
    );
    final FakePlaybackController engine = FakePlaybackController();
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        jellyfinClientProvider.overrideWithValue(client),
        localPlaybackControllerProvider.overrideWithValue(engine),
      ],
    );
    addTearDown(container.dispose);
    // What main() reads after startup.
    container.read(playbackReportingServiceProvider);
    final JellyfinSettingsController settings =
        container.read(jellyfinSettingsControllerProvider.notifier);
    await settings.ensureLoaded();

    Future<void> signInAs(String userId) async {
      client.authResult =
          JellyfinAuthResult(accessToken: '$userId-token', userId: userId);
      expect(
        await settings.signIn(
          url: 'https://jellyfin.example.com',
          username: userId,
          password: 'pw',
        ),
        isTrue,
      );
    }

    Future<void> emit(PlaybackState state) async {
      engine.emit(state);
      // Let the reporting service dispatch.
      await pumpEventQueue();
    }

    // Alice listens on the family tablet.
    await signInAs('alice');
    await emit(const PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: _first,
      upNext: <Track>[_second, _third],
    ));

    // She signs out. Playback goes on, and the queue moves to the next song
    // (it was pre-cached, so it plays without a server) before anyone signs
    // in again.
    await settings.clear();
    await emit(const PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: _second,
      previous: <Track>[_first],
      upNext: <Track>[_third],
      position: Duration(seconds: 5),
    ));

    // Bob signs in on the same server while that song plays on, and it plays
    // to its end.
    final int before = client.playbackReports.length;
    await signInAs('bob');
    await emit(const PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: _second,
      previous: <Track>[_first],
      upNext: <Track>[_third],
      position: Duration(minutes: 2, seconds: 59),
    ));
    await emit(const PlaybackState(
      status: PlaybackStatus.completed,
      currentTrack: _second,
      previous: <Track>[_first],
      upNext: <Track>[_third],
    ));

    final List<String> toBob = <String>[
      for (final report in client.playbackReports.skip(before))
        '${report.event.name}:${report.itemId}',
    ];
    expect(toBob, isEmpty,
        reason: 'the song started before bob signed in, so his account must '
            'not be told it was played');
  });
}
