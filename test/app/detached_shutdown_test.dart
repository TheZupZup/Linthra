import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/application_lifecycle.dart';
import 'package:linthra/app/linthra_app.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/notification_permission.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/features/player/player_providers.dart';

import '../features/player/fake_playback_controller.dart';
import '../support/onboarding_test_overrides.dart';

/// Notification-permission seam that never prompts, so pumping the app can't
/// trigger a real OS dialog.
class _SilentNotificationPermission implements NotificationPermission {
  @override
  Future<void> ensureGranted() async {}

  @override
  Future<NotificationPermissionStatus> status() async =>
      NotificationPermissionStatus.unknown;
}

const Track _playingTrack = Track(id: 'a', title: 'Song A', uri: '/a.mp3');

/// Drives the app all the way down to `detached` through the legal lifecycle
/// chain Flutter's binding enforces.
Future<void> _detach(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
  await tester.pump();
}

Future<(ApplicationHandle, FakePlaybackController)> _pumpApp(
  WidgetTester tester, {
  required HostPlatform host,
}) async {
  final FakePlaybackController controller = FakePlaybackController(
    initial: const PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: _playingTrack,
    ),
  );
  // One container behind both the widget tree and the handle, exactly as
  // `main()` wires it — so a shutdown really does reach the app's playback
  // controller rather than an unrelated scope.
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      ...completedOnboardingOverrides(),
      hostPlatformProvider.overrideWithValue(host),
      notificationPermissionProvider
          .overrideWithValue(_SilentNotificationPermission()),
      playbackControllerProvider.overrideWithValue(controller),
    ],
  );
  final ApplicationHandle handle = ApplicationHandle(container: container);
  // Not `handle.shutdown` — awaiting a full teardown inside the widget
  // tester's fake-async zone would park on work only the real event loop
  // advances. Disposing the container releases the test's own resources.
  addTearDown(() {
    if (!handle.isShuttingDown) container.dispose();
  });

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: LinthraApp(lifecycle: handle),
    ),
  );
  await tester.pumpAndSettle();
  return (handle, controller);
}

void main() {
  testWidgets('detaching on Linux runs the graceful shutdown', (tester) async {
    final (ApplicationHandle handle, FakePlaybackController controller) =
        await _pumpApp(tester, host: HostPlatform.linux);

    await _detach(tester);
    // The widget fires the shutdown without awaiting it; pumping lets its
    // first steps run.
    await tester.pump();

    expect(handle.isShuttingDown, isTrue);
    // The window is closing and the process is ending: playback stops with it.
    expect(controller.stopCount, greaterThanOrEqualTo(1));
  });

  testWidgets(
      'closing the window on Linux runs the graceful shutdown before exiting',
      (tester) async {
    final (ApplicationHandle handle, FakePlaybackController controller) =
        await _pumpApp(tester, host: HostPlatform.linux);

    // What the Linux embedder does when the window is closed: FlView's
    // delete-event handler sends System.requestAppExit, and the application
    // quits as soon as the answer is "exit". It never sends `detached`.
    final AppExitResponse? response = await tester.runAsync(
      () => tester.binding.handleRequestAppExit(),
    );

    expect(response, AppExitResponse.exit);
    // By the time the app is allowed to exit, the shutdown has run to the
    // end: playback was stopped and the engine released, which is the order
    // the saved session and the servers' "stopped" depend on.
    expect(handle.isShuttingDown, isTrue);
    expect(controller.stopCount, greaterThanOrEqualTo(1));
    expect(controller.disposed, isTrue);
  });

  testWidgets('a shutdown that never finishes does not keep the window open',
      (tester) async {
    final (ApplicationHandle handle, FakePlaybackController _) =
        await _pumpApp(tester, host: HostPlatform.linux);
    // A resource whose teardown never completes.
    final Completer<void> wedged = Completer<void>();
    handle.own(() => wedged.future);

    AppExitResponse? response;
    unawaited(
      tester.binding.handleRequestAppExit().then((AppExitResponse r) {
        response = r;
      }),
    );
    // Well inside the bound, then well past it, so the test holds whatever
    // the exact bound is tuned to.
    await tester.pump(const Duration(seconds: 1));
    expect(response, isNull, reason: 'still giving the shutdown its chance');

    await tester.pump(const Duration(seconds: 10));
    expect(response, AppExitResponse.exit);

    // Let the wedged teardown go, so the test leaves nothing running.
    wedged.complete();
    await tester.pump();
  });

  testWidgets('an exit request on Android never shuts the application down',
      (tester) async {
    final (ApplicationHandle handle, FakePlaybackController controller) =
        await _pumpApp(tester, host: HostPlatform.android);

    final AppExitResponse? response = await tester.runAsync(
      () => tester.binding.handleRequestAppExit(),
    );

    expect(response, AppExitResponse.exit);
    expect(handle.isShuttingDown, isFalse);
    expect(controller.stopCount, 0);
  });

  testWidgets('detaching on Android never shuts the application down',
      (tester) async {
    final (ApplicationHandle handle, FakePlaybackController controller) =
        await _pumpApp(tester, host: HostPlatform.android);

    await _detach(tester);

    // `detached` on Android also means "the Activity went away while the
    // foreground service keeps playing" — tearing the app down here would kill
    // background audio and leave a re-attached UI on a disposed container.
    expect(handle.isShuttingDown, isFalse);
    expect(controller.stopCount, 0);
    expect(controller.pauseCount, 0);
    expect(controller.disposed, isFalse);
    expect(controller.state.status, PlaybackStatus.playing);
  });

  testWidgets('backgrounding on Linux does not shut the application down',
      (tester) async {
    final (ApplicationHandle handle, FakePlaybackController controller) =
        await _pumpApp(tester, host: HostPlatform.linux);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    expect(handle.isShuttingDown, isFalse);
    expect(controller.stopCount, 0);
    expect(controller.state.status, PlaybackStatus.playing);
  });
}
