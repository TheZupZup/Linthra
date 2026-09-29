import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/linthra_app.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/services/notification_permission.dart';
import 'package:linthra/core/sources/subsonic/subsonic_account_fingerprint.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_session_store.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_sync_pending_store.dart';
import 'package:linthra/data/repositories/subsonic_session_store_provider.dart';
import 'package:linthra/data/repositories/subsonic_sync_pending_store_provider.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_controller.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_providers.dart';

import '../core/sources/subsonic/synthetic_navidrome.dart';
import '../features/player/fake_playback_controller.dart';
import '../support/onboarding_test_overrides.dart';

/// Notification-permission seam that never prompts.
class _SilentNotificationPermission implements NotificationPermission {
  @override
  Future<void> ensureGranted() async {}

  @override
  Future<NotificationPermissionStatus> status() async =>
      NotificationPermissionStatus.unknown;
}

const SubsonicSession _alice = SubsonicSession(
  baseUrl: 'https://music.example.com',
  username: 'alice',
  salt: 'salt',
  token: 'token',
);

Future<void> _background(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  await tester.pump();
}

Future<void> _foreground(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpAndSettle();
}

/// Pumps the app signed in to [server] as alice, with [pending] as the
/// unfinished-sync record, and waits for the saved session to load (bootstrap
/// does that before the first frame in the real app).
Future<void> _pumpApp(
  WidgetTester tester, {
  required SyntheticNavidrome server,
  required InMemorySubsonicSyncPendingStore pending,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...completedOnboardingOverrides(),
        notificationPermissionProvider
            .overrideWithValue(_SilentNotificationPermission()),
        playbackControllerProvider.overrideWithValue(
          FakePlaybackController(initial: const PlaybackState()),
        ),
        subsonicClientProvider.overrideWithValue(server.client()),
        subsonicSessionStoreProvider.overrideWithValue(
          InMemorySubsonicSessionStore(initialSession: _alice),
        ),
        subsonicSyncPendingStoreProvider.overrideWithValue(pending),
      ],
      child: const LinthraApp(),
    ),
  );
  await tester.pumpAndSettle();
  await ProviderScope.containerOf(tester.element(find.byType(LinthraApp)))
      .read(subsonicSettingsControllerProvider.notifier)
      .ensureLoaded();
}

void main() {
  testWidgets('coming back to the app resumes an unfinished Subsonic sync',
      (tester) async {
    // #680: Android froze or killed the app partway through a sync.
    final SyntheticNavidrome server = SyntheticNavidrome(albums: 3);
    final InMemorySubsonicSyncPendingStore pending =
        InMemorySubsonicSyncPendingStore(subsonicAccountFingerprint(_alice));
    await _pumpApp(tester, server: server, pending: pending);

    await _background(tester);
    expect(server.albumCalls, 0);
    await _foreground(tester);

    expect(server.albumCalls, 3);
    expect(await pending.read(), isNull);
  });

  testWidgets('coming back to the app syncs nothing when no sync is unfinished',
      (tester) async {
    final SyntheticNavidrome server = SyntheticNavidrome(albums: 3);
    await _pumpApp(
      tester,
      server: server,
      pending: InMemorySubsonicSyncPendingStore(),
    );

    await _background(tester);
    await _foreground(tester);

    expect(server.albumListCalls, 0);
    expect(server.albumCalls, 0);
  });
}
