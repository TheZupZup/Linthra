import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/application_lifecycle.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_session_store.dart';
import 'package:linthra/data/repositories/jellyfin_session_store_provider.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_providers.dart';

import '../core/sources/jellyfin/fake_jellyfin_client.dart';
import '../support/counting_audio_player.dart';
import '../support/lifecycle_test_graph.dart';
import '../support/recording_media_session.dart';
import '../support/recording_remote_control_receiver.dart';

/// A server that records every report it answers.
class _Server extends FakeJellyfinClient {
  List<String> get events => <String>[
        for (final report in playbackReports) report.event.name,
      ];

  /// While set, a pause report is held here before it is answered: the
  /// server is still answering it when the listener quits.
  Completer<void>? holdPause;

  /// The session each report went out with, in order.
  final List<JellyfinSession> sessions = <JellyfinSession>[];

  @override
  Future<void> reportPlayback(
    JellyfinSession session, {
    required String itemId,
    required JellyfinPlaybackEvent event,
    required Duration position,
  }) async {
    sessions.add(session);
    final Completer<void>? hold = holdPause;
    if (event == JellyfinPlaybackEvent.paused && hold != null) {
      await hold.future;
    }
    return super.reportPlayback(
      session,
      itemId: itemId,
      event: event,
      position: position,
    );
  }
}

const JellyfinSession _session = JellyfinSession(
  baseUrl: 'http://192.168.22.1:8096',
  userId: 'user-1',
  accessToken: 'tok',
  deviceId: 'device-1',
);

const Track _song = Track(
  id: 'item-1',
  title: 'Hello',
  uri: 'jellyfin:item-1',
  duration: Duration(minutes: 3),
);

/// The Linux app, signed in to [server], playing [_song].
Future<(ProviderContainer, ApplicationHandle)> _playing(
  _Server server, {
  CountingAudioPlayer? player,
  Duration closingReportDeadline =
      ApplicationHandle.defaultClosingReportDeadline,
}) async {
  final ProviderContainer container = ProviderContainer(
    overrides: linuxLifecycleOverrides(
      audioPlayer: player ?? CountingAudioPlayer(),
      remoteControlReceiver: RecordingRemoteControlReceiver(),
      extra: <Override>[
        jellyfinSessionStoreProvider.overrideWithValue(
          InMemoryJellyfinSessionStore(initialSession: _session),
        ),
        jellyfinClientProvider.overrideWithValue(server),
      ],
    ),
  );
  final ApplicationHandle handle = await bootstrapApplication(
    container,
    installPersistentArtworkCache: false,
    mediaSessionBinding:
        RecordingMediaSessionBinding(session: RecordingMediaSession()),
    closingReportDeadline: closingReportDeadline,
  );
  await container.read(playbackControllerProvider).playTrack(_song);
  await pumpEventQueue();
  expect(container.read(playbackControllerProvider).state.status,
      PlaybackStatus.playing);
  return (container, handle);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Quitting is what tells the server the player went away: the reason a
  // window close runs the graceful shutdown at all. Without the stop, the
  // server's dashboard keeps showing Linthra as an active player after it quit.
  group('quitting tells the server playback stopped', () {
    test('while playing', () async {
      final _Server server = _Server();
      final (_, ApplicationHandle handle) = await _playing(server);

      await handle.shutdown();
      await pumpEventQueue();

      expect(server.events, <String>['started', 'stopped']);
    });

    test('while paused', () async {
      final _Server server = _Server();
      final (ProviderContainer container, ApplicationHandle handle) =
          await _playing(server);
      await container.read(playbackControllerProvider).pause();
      await pumpEventQueue();

      await handle.shutdown();
      await pumpEventQueue();

      expect(server.events, <String>['started', 'paused', 'stopped']);
    });

    // #838: the pause report is still out when the listener quits. The
    // closing stop waits behind it, and by its turn the app is torn down.
    test('while the server is still answering the pause', () async {
      final _Server server = _Server()..holdPause = Completer<void>();
      final CountingAudioPlayer player = CountingAudioPlayer();
      final (ProviderContainer container, ApplicationHandle handle) =
          await _playing(server, player: player);
      await container.read(playbackControllerProvider).pause();
      await pumpEventQueue();
      expect(server.sessions, hasLength(2), reason: 'the pause is out');

      bool quit = false;
      final Future<void> quitting =
          handle.shutdown().whenComplete(() => quit = true);
      await pumpEventQueue();

      // The speakers went quiet and the app came down without waiting for
      // the server.
      expect(player.disposeCount, greaterThan(0));
      expect(quit, isFalse, reason: 'shutdown gives the stop a moment');

      server.holdPause!.complete();
      await quitting;

      expect(server.events, <String>['started', 'paused', 'stopped']);
      // To the account the play belonged to, read before it was torn down.
      expect(server.sessions.last, _session);
    });

    test('a server that never answers does not hold up the quit', () async {
      final _Server server = _Server()..holdPause = Completer<void>();
      final CountingAudioPlayer player = CountingAudioPlayer();
      final (ProviderContainer container, ApplicationHandle handle) =
          await _playing(
        server,
        player: player,
        closingReportDeadline: const Duration(milliseconds: 50),
      );
      await container.read(playbackControllerProvider).pause();
      await pumpEventQueue();

      await handle.shutdown().timeout(const Duration(seconds: 5));

      expect(player.disposeCount, greaterThan(0));
      // The stop is still behind the pause nobody answered: not sent, and not
      // sent out of order either.
      expect(server.events, <String>['started']);
      expect(server.sessions, hasLength(2));
    });
  });
}
