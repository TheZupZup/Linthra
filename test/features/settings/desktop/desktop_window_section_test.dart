import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/desktop_close_behavior.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/desktop_window_controller.dart';
import 'package:linthra/data/repositories/desktop_window_controller_provider.dart';
import 'package:linthra/data/repositories/desktop_window_preferences_provider.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_desktop_window_preferences.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/settings/desktop/desktop_window_section.dart';
import 'package:linthra/features/settings/hub/music_and_playback_screen.dart';

import '../../player/fake_playback_controller.dart';

/// Records what the card asked the window to do.
class _RecordingWindow implements DesktopWindowController {
  int quitCount = 0;

  @override
  Future<void> setHideOnClose(bool hideOnClose) async {}

  @override
  Future<void> showWindow() async {}

  @override
  Future<void> quit() async => quitCount++;

  @override
  Stream<DesktopWindowVisibility> get visibility =>
      const Stream<DesktopWindowVisibility>.empty();
}

void main() {
  group('DesktopWindowSettingsSection', () {
    late InMemoryDesktopWindowPreferences preferences;
    late _RecordingWindow window;

    Future<ProviderContainer> pump(
      WidgetTester tester, {
      DesktopCloseBehavior stored = DesktopCloseBehavior.quit,
      Widget child = const DesktopWindowSettingsSection(),
      HostPlatform host = HostPlatform.linux,
    }) async {
      preferences = InMemoryDesktopWindowPreferences(closeBehavior: stored);
      window = _RecordingWindow();
      final FakePlaybackController playback = FakePlaybackController();
      addTearDown(playback.dispose);
      final container = ProviderContainer(
        overrides: [
          desktopWindowPreferencesProvider.overrideWithValue(preferences),
          desktopWindowControllerProvider.overrideWithValue(window),
          hostPlatformProvider.overrideWithValue(host),
          // The quit path reaches the playback controller; the real one on
          // Linux opens libmpv.
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
      return container;
    }

    testWidgets('offers both close behaviours and a way out', (tester) async {
      await pump(tester);

      expect(find.text('Desktop window'), findsOneWidget);
      expect(find.text('Quit Linthra'), findsOneWidget);
      expect(find.text('Keep playing in the background'), findsOneWidget);
      expect(find.text('Quit Linthra now'), findsOneWidget);
    });

    testWidgets('starts on the stored choice', (tester) async {
      await pump(tester, stored: DesktopCloseBehavior.keepPlaying);

      final RadioGroup<DesktopCloseBehavior> group =
          tester.widget(find.byType(RadioGroup<DesktopCloseBehavior>));
      expect(group.groupValue, DesktopCloseBehavior.keepPlaying);
    });

    testWidgets('choosing background playback persists it', (tester) async {
      await pump(tester);
      expect(await preferences.closeBehavior(), DesktopCloseBehavior.quit);

      await tester.tap(find.text('Keep playing in the background'));
      await tester.pumpAndSettle();

      expect(
        await preferences.closeBehavior(),
        DesktopCloseBehavior.keepPlaying,
      );
    });

    testWidgets('Quit now ends the app', (tester) async {
      await pump(tester);

      await tester.tap(find.text('Quit Linthra now'));
      await tester.pumpAndSettle();

      expect(window.quitCount, 1);
    });

    testWidgets('the Music & playback page shows the card on a desktop',
        (tester) async {
      // Tall enough for the whole page: the card is the last one on it, and a
      // ListView does not build what it cannot show.
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pump(tester, child: const MusicAndPlaybackScreen());

      expect(find.byType(DesktopWindowSettingsSection), findsOneWidget);
    });

    testWidgets('Android never sees it: there is no window to close there',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pump(
        tester,
        child: const MusicAndPlaybackScreen(),
        host: HostPlatform.android,
      );

      expect(find.byType(DesktopWindowSettingsSection), findsNothing);
    });
  });
}
