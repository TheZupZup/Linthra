import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/linthra_app.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/notification_permission.dart';
import 'package:linthra/core/services/stability_diagnostics.dart';
import 'package:linthra/features/player/player_providers.dart';

import '../features/player/fake_playback_controller.dart';

/// Notification-permission seam that never prompts, so pumping the app can't
/// trigger a real OS dialog.
class _SilentNotificationPermission implements NotificationPermission {
  @override
  Future<void> ensureGranted() async {}

  @override
  Future<NotificationPermissionStatus> status() async =>
      NotificationPermissionStatus.unknown;
}

/// Notification-permission seam whose request *fails* (denied + a plugin
/// hiccup), so a test can prove a failing request never crashes startup. The
/// async throw becomes a rejected Future, exactly as a real plugin failure
/// would surface to the fire-and-forget call site.
class _FailingNotificationPermission implements NotificationPermission {
  @override
  Future<void> ensureGranted() async =>
      throw Exception('notification permission request failed');

  @override
  Future<NotificationPermissionStatus> status() async =>
      NotificationPermissionStatus.denied;
}

const _playingTrack = Track(id: 'a', title: 'Song A', uri: '/a.mp3');

/// Drives the app from `resumed` down to `paused` through the legal lifecycle
/// chain Flutter's binding enforces (resumed → inactive → hidden → paused).
Future<void> _background(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  await tester.pump();
}

/// Drives the app back up to `resumed` (paused → hidden → inactive → resumed).
Future<void> _foreground(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pump();
}

Future<FakePlaybackController> _pumpApp(
  WidgetTester tester, {
  NotificationPermission? permission,
}) async {
  final controller = FakePlaybackController(
    initial: const PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: _playingTrack,
    ),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        notificationPermissionProvider
            .overrideWithValue(permission ?? _SilentNotificationPermission()),
        playbackControllerProvider.overrideWithValue(controller),
      ],
      child: const LinthraApp(),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets('backgrounding the app never pauses or stops active playback',
      (tester) async {
    final controller = await _pumpApp(tester);

    await _background(tester);

    // The screen-off bug guard: a background transition must not touch
    // transport at all — the foreground service keeps audio alive instead.
    expect(controller.pauseCount, 0);
    expect(controller.stopCount, 0);
    expect(controller.playedTracks, isEmpty);
  });

  testWidgets('returning to the foreground does not restart playback',
      (tester) async {
    final controller = await _pumpApp(tester);

    await _background(tester);
    await _foreground(tester);

    // No re-load (playTracks) and no extra play(): the engine is left running.
    expect(controller.playedTracks, isEmpty);
    expect(controller.playCount, 0);
    expect(controller.pauseCount, 0);
    expect(controller.stopCount, 0);
  });

  testWidgets('a background transition records the playback state for reports',
      (tester) async {
    StabilityDiagnostics.playbackStateAtBackground = null;
    await _pumpApp(tester);

    await _background(tester);

    // The "music stopped when I locked the phone" breadcrumb: the status at the
    // background boundary is captured (here, playing) for the bug report.
    expect(StabilityDiagnostics.playbackStateAtBackground, 'playing');
    expect(StabilityDiagnostics.lastLifecycleState, 'paused');
  });

  testWidgets(
      'a failing notification-permission request never crashes startup or '
      'disturbs playback', (tester) async {
    final controller =
        await _pumpApp(tester, permission: _FailingNotificationPermission());

    // The Android 13+ POST_NOTIFICATIONS request rejected, but the app built
    // and playback was untouched — background audio works without the grant
    // (only the notification / lock-screen controls are suppressed).
    expect(tester.takeException(), isNull);
    expect(controller.pauseCount, 0);
    expect(controller.stopCount, 0);
    expect(controller.playedTracks, isEmpty);
  });
}
