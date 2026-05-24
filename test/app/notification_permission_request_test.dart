import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/linthra_app.dart';
import 'package:linthra/core/services/notification_permission.dart';
import 'package:linthra/features/player/player_providers.dart';

import '../features/player/fake_playback_controller.dart';

/// Records how many times the app asked for the notification permission, so a
/// test can assert the first-launch request fires exactly once without a real
/// OS prompt.
class _RecordingNotificationPermission implements NotificationPermission {
  int calls = 0;

  @override
  Future<void> ensureGranted() async {
    calls += 1;
  }
}

void main() {
  testWidgets('requests the notification permission once on first launch',
      (tester) async {
    final permission = _RecordingNotificationPermission();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notificationPermissionProvider.overrideWithValue(permission),
          playbackControllerProvider
              .overrideWithValue(FakePlaybackController()),
        ],
        child: const LinthraApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(permission.calls, 1);

    // A rebuild (e.g. a frame later) does not re-prompt: the request is tied to
    // the one-time post-first-frame callback, not to build.
    await tester.pump();
    expect(permission.calls, 1);
  });
}
