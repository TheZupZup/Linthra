import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/linthra_app.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/notification_permission.dart';
import 'package:linthra/core/services/playback_controller.dart';
import 'package:linthra/features/player/player_providers.dart';

import '../support/counting_audio_player.dart';
import '../support/fake_machine_sleep.dart';
import '../support/lifecycle_test_graph.dart';
import '../support/onboarding_test_overrides.dart';

class _SilentNotificationPermission implements NotificationPermission {
  @override
  Future<void> ensureGranted() async {}

  @override
  Future<NotificationPermissionStatus> status() async =>
      NotificationPermissionStatus.unknown;
}

/// Records every source the Linux engine is asked to open.
class _RecordingPlayer extends CountingAudioPlayer {
  final List<String> opened = <String>[];

  @override
  Future<Duration?> setUrl(
    String url, {
    Map<String, String>? headers,
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) {
    opened.add(url);
    return super.setUrl(url);
  }
}

const Track _song = Track(id: 'a', title: 'Song', uri: '/music/a.mp3');

/// The lifecycle states the Linux embedder actually sends: `resumed` with
/// focus, `inactive` without it, `hidden` when minimized or withdrawn. Never
/// `paused`, which is what the reload used to wait for (#799).
void _lifecycle(WidgetTester tester, AppLifecycleState state) =>
    tester.binding.handleAppLifecycleStateChanged(state);

/// Pumps the app on the Linux playback graph (the real
/// `ActivePlaybackController` over the real `LinuxPlaybackController`), with
/// [machine]'s clocks behind its sleep watcher, playing [_song].
Future<(_RecordingPlayer, PlaybackController)> _pumpPlaying(
  WidgetTester tester,
  FakeMachineSleep machine,
) async {
  final _RecordingPlayer player = _RecordingPlayer();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        ...linuxLifecycleOverrides(audioPlayer: player),
        ...completedOnboardingOverrides(),
        notificationPermissionProvider
            .overrideWithValue(_SilentNotificationPermission()),
        linuxSleepWatcherProvider.overrideWithValue(machine.watcher()),
      ],
      child: const LinthraApp(),
    ),
  );
  await tester.pumpAndSettle();
  final ProviderContainer container =
      ProviderScope.containerOf(tester.element(find.byType(LinthraApp)));
  (container.read(localPlaybackControllerProvider)
          as JustAudioPlaybackController)
      .suspendResumeBackoff = Duration.zero;
  final PlaybackController playback =
      container.read(playbackControllerProvider);
  await tester.runAsync(() => playback.playTrack(_song));
  expect(playback.state.status, PlaybackStatus.playing);
  expect(player.opened, hasLength(1));
  return (player, playback);
}

/// Lets a wake the watcher noticed reach the engine and its reload run.
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

void main() {
  testWidgets('a sleep while playing reloads the track once (#799)',
      (WidgetTester tester) async {
    final FakeMachineSleep machine = FakeMachineSleep();
    final (_RecordingPlayer player, PlaybackController playback) =
        await _pumpPlaying(tester, machine);

    // A lid close: the lock screen takes focus, the machine sleeps for an
    // hour, and focus comes back once the listener unlocks after the wake.
    _lifecycle(tester, AppLifecycleState.inactive);
    await tester.pump();
    machine.sleep(const Duration(hours: 1));
    machine.look();
    await _settle(tester);
    _lifecycle(tester, AppLifecycleState.resumed);
    await _settle(tester);

    expect(player.opened, hasLength(2),
        reason: 'the track playing across the sleep is reloaded once');
    expect(playback.state.currentTrack?.uri, _song.uri);

    // Nothing else comes of the wake: looking again, or the window coming
    // and going, reloads nothing more.
    machine.look();
    _lifecycle(tester, AppLifecycleState.inactive);
    _lifecycle(tester, AppLifecycleState.resumed);
    await _settle(tester);
    expect(player.opened, hasLength(2));
    player.dispose().ignore();
  });

  testWidgets('a sleep with no focus change at all is noticed just the same',
      (WidgetTester tester) async {
    // A window manager with no lock screen sends Flutter nothing around a
    // suspend.
    final FakeMachineSleep machine = FakeMachineSleep();
    final (_RecordingPlayer player, _) = await _pumpPlaying(tester, machine);

    machine.sleep(const Duration(minutes: 12));
    machine.look();
    await _settle(tester);

    expect(player.opened, hasLength(2));
    player.dispose().ignore();
  });

  testWidgets('a minimized window is not a sleep: nothing reloads',
      (WidgetTester tester) async {
    final FakeMachineSleep machine = FakeMachineSleep();
    final (_RecordingPlayer player, PlaybackController playback) =
        await _pumpPlaying(tester, machine);

    // Minimized (or closed to the background) for an hour of music: the
    // watcher keeps looking and the clocks keep agreeing.
    _lifecycle(tester, AppLifecycleState.inactive);
    _lifecycle(tester, AppLifecycleState.hidden);
    await tester.pump();
    for (int i = 0; i < 1800; i++) {
      machine.look();
    }
    await _settle(tester);
    _lifecycle(tester, AppLifecycleState.inactive);
    _lifecycle(tester, AppLifecycleState.resumed);
    await _settle(tester);

    expect(player.opened, hasLength(1),
        reason: 'music that kept playing is never reloaded');
    expect(playback.state.status, PlaybackStatus.playing);
    player.dispose().ignore();
  });

  testWidgets('a sleep while the window is hidden is still recovered',
      (WidgetTester tester) async {
    // Closed to the background, then the laptop is suspended: the audio
    // device went down under the engine all the same.
    final FakeMachineSleep machine = FakeMachineSleep();
    final (_RecordingPlayer player, _) = await _pumpPlaying(tester, machine);

    _lifecycle(tester, AppLifecycleState.inactive);
    _lifecycle(tester, AppLifecycleState.hidden);
    await tester.pump();
    machine.sleep(const Duration(minutes: 45));
    machine.look();
    await _settle(tester);

    expect(player.opened, hasLength(2));
    player.dispose().ignore();
  });

  testWidgets('a track paused before the sleep stays paused after it',
      (WidgetTester tester) async {
    final FakeMachineSleep machine = FakeMachineSleep();
    final (_RecordingPlayer player, PlaybackController playback) =
        await _pumpPlaying(tester, machine);
    await tester.runAsync(playback.pause);
    await tester.pump();
    final int plays = player.playCount;

    _lifecycle(tester, AppLifecycleState.inactive);
    machine.sleep(const Duration(hours: 7));
    machine.look();
    await _settle(tester);
    _lifecycle(tester, AppLifecycleState.resumed);
    await _settle(tester);

    expect(player.opened, hasLength(1));
    expect(player.playCount, plays);
    expect(playback.state.status, PlaybackStatus.paused);
    player.dispose().ignore();
  });
}
