import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/notifications/desktop_notifier.dart';
import 'package:linthra/data/repositories/desktop_notification_preferences_provider.dart';
import 'package:linthra/data/repositories/desktop_notifier_provider.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_desktop_notification_preferences.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/settings/desktop/desktop_notifications_section.dart';
import 'package:linthra/features/settings/hub/music_and_playback_screen.dart';

import '../../player/fake_playback_controller.dart';

/// A notifier that only answers whether it exists: enough for a card that
/// decides whether to render.
class _StubNotifier implements DesktopNotifier {
  const _StubNotifier({required this.isSupported});

  @override
  final bool isSupported;

  @override
  Future<void> show(DesktopNotification notification) async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  group('DesktopNotificationsSettingsSection', () {
    late InMemoryDesktopNotificationPreferences preferences;

    Future<void> pump(
      WidgetTester tester, {
      bool stored = false,
      bool supported = true,
      Widget child = const DesktopNotificationsSettingsSection(),
      HostPlatform host = HostPlatform.linux,
    }) async {
      preferences =
          InMemoryDesktopNotificationPreferences(trackChanges: stored);
      final FakePlaybackController playback = FakePlaybackController();
      addTearDown(playback.dispose);
      final container = ProviderContainer(
        overrides: <Override>[
          desktopNotificationPreferencesProvider.overrideWithValue(preferences),
          desktopNotifierProvider
              .overrideWithValue(_StubNotifier(isSupported: supported)),
          hostPlatformProvider.overrideWithValue(host),
          // The Music & playback page reaches the playback controller; the
          // real one on Linux opens libmpv.
          playbackControllerProvider.overrideWithValue(playback),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: Scaffold(body: child)),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('says what it does, and starts off', (tester) async {
      await pump(tester);

      expect(find.text('Desktop notifications'), findsOneWidget);
      expect(find.text('Notify me when the track changes'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isFalse);
    });

    testWidgets('reflects a stored choice', (tester) async {
      await pump(tester, stored: true);

      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isTrue);
    });

    testWidgets('turning it on persists the choice', (tester) async {
      await pump(tester);

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(await preferences.trackChangeNotifications(), isTrue);
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isTrue);
    });

    testWidgets('turning it off again persists that too', (tester) async {
      await pump(tester, stored: true);

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(await preferences.trackChangeNotifications(), isFalse);
    });

    testWidgets('renders nothing where notifications are unsupported',
        (tester) async {
      await pump(tester, supported: false);

      expect(find.byType(SwitchListTile), findsNothing);
      expect(find.text('Desktop notifications'), findsNothing);
    });

    testWidgets('the Music & playback page shows the card on a desktop',
        (tester) async {
      // Tall enough for the whole page: the card is the last one on it, and a
      // ListView does not build what it cannot show.
      tester.view.physicalSize = const Size(1200, 3600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pump(tester, child: const MusicAndPlaybackScreen());

      expect(
        find.byType(DesktopNotificationsSettingsSection),
        findsOneWidget,
      );
    });

    testWidgets('Android never sees it: its notification is the session’s',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 3600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pump(
        tester,
        child: const MusicAndPlaybackScreen(),
        host: HostPlatform.android,
        supported: false,
      );

      expect(find.byType(DesktopNotificationsSettingsSection), findsNothing);
    });
  });
}
