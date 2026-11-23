import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/linthra_app.dart';
import 'package:linthra/core/models/theme_mode_preference.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_theme_mode_store.dart';
import 'package:linthra/data/repositories/theme_mode_store_provider.dart';
import 'package:linthra/features/appearance/theme_mode_controller.dart';
import 'package:linthra/features/player/player_providers.dart';

import '../features/player/fake_playback_controller.dart';
import '../support/onboarding_test_overrides.dart';

/// End-to-end theme-mode behaviour, driven through the real [LinthraApp] so the
/// wiring (controller → `MaterialApp.themeMode`) is covered, not just the
/// controller in isolation.
void main() {
  /// The brightness Linthra is *actually rendering*, read from the resolved
  /// theme inside the app rather than from the `themeMode` we passed in.
  Brightness renderedBrightness(WidgetTester tester) {
    final BuildContext context = tester.element(find.byType(Navigator).first);
    return Theme.of(context).brightness;
  }

  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    ThemeModePreference? seed,
    InMemoryThemeModeStore? store,
    HostPlatform? host,
  }) async {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        ...completedOnboardingOverrides(),
        playbackControllerProvider.overrideWithValue(FakePlaybackController()),
        if (store != null) themeModeStoreProvider.overrideWithValue(store),
        if (seed != null) initialThemeModeProvider.overrideWithValue(seed),
        if (host != null) hostPlatformProvider.overrideWithValue(host),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const LinthraApp(),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  /// Sets the device's light/dark setting for this test.
  void setDeviceBrightness(WidgetTester tester, Brightness brightness) {
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  }

  group('theme mode follows the device by default', () {
    testWidgets('defaults to ThemeMode.system', (tester) async {
      setDeviceBrightness(tester, Brightness.dark);
      await pumpApp(tester);

      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.system,
      );
    });

    testWidgets('renders light on a light device', (tester) async {
      setDeviceBrightness(tester, Brightness.light);
      await pumpApp(tester);

      expect(renderedBrightness(tester), Brightness.light);
    });

    testWidgets('renders dark on a dark device', (tester) async {
      setDeviceBrightness(tester, Brightness.dark);
      await pumpApp(tester);

      expect(renderedBrightness(tester), Brightness.dark);
    });

    testWidgets('flips live when the device theme changes while open',
        (tester) async {
      // The "update immediately" requirement: no relaunch, no navigation, no
      // listener of our own — just the OS setting changing under a running app.
      setDeviceBrightness(tester, Brightness.light);
      await pumpApp(tester);
      expect(renderedBrightness(tester), Brightness.light);

      setDeviceBrightness(tester, Brightness.dark);
      await tester.pumpAndSettle();
      expect(renderedBrightness(tester), Brightness.dark);

      // And back again, so this is a live binding rather than a one-way latch.
      setDeviceBrightness(tester, Brightness.light);
      await tester.pumpAndSettle();
      expect(renderedBrightness(tester), Brightness.light);
    });
  });

  group('an explicit choice overrides the device', () {
    testWidgets('Light stays light on a dark device', (tester) async {
      setDeviceBrightness(tester, Brightness.dark);
      await pumpApp(tester, seed: ThemeModePreference.light);

      expect(renderedBrightness(tester), Brightness.light);
    });

    testWidgets('Dark stays dark on a light device', (tester) async {
      setDeviceBrightness(tester, Brightness.light);
      await pumpApp(tester, seed: ThemeModePreference.dark);

      expect(renderedBrightness(tester), Brightness.dark);
    });

    testWidgets('a pinned mode ignores a live device theme change',
        (tester) async {
      setDeviceBrightness(tester, Brightness.light);
      await pumpApp(tester, seed: ThemeModePreference.dark);
      expect(renderedBrightness(tester), Brightness.dark);

      setDeviceBrightness(tester, Brightness.dark);
      await tester.pumpAndSettle();
      expect(renderedBrightness(tester), Brightness.dark);

      setDeviceBrightness(tester, Brightness.light);
      await tester.pumpAndSettle();
      expect(
        renderedBrightness(tester),
        Brightness.dark,
        reason: 'pinning Dark must survive the device flipping to light',
      );
    });
  });

  group('theme resolution is not gated by HostPlatform', () {
    // Regression guard for #459, and deliberately narrow about what it proves.
    //
    // What it DOES prove: ThemeModeController/LinthraApp never branch on
    // HostPlatform the way other platform seams do (see docs/linux/desktop.md
    // "How platform selection works") — System/Light/Dark resolve through the
    // one shared path Android already used, regardless of what
    // hostPlatformProvider is overridden to. If a future change forked theme
    // resolution by platform, pinning HostPlatform.linux here and getting a
    // *different* result than the unpinned groups above would catch it.
    //
    // What it does NOT prove: anything about the real Linux GTK/XDG-desktop-
    // portal brightness bridge. `platformBrightnessTestValue` above injects a
    // Brightness straight into Flutter's own test PlatformDispatcher; it never
    // touches the native embedder, and overriding hostPlatformProvider changes
    // nothing about what gets rendered here — which is exactly the point of
    // this group, not a gap in it. Supplying the *real* platform brightness on
    // Linux is the Flutter engine's job (`fl_settings.cc`, via the desktop
    // portal or a GNOME GSettings fallback), not Linthra's, and reproducing
    // that deterministically in `flutter test` or headless CI would need a
    // running portal daemon or GNOME schemas — exactly the DE-specific
    // machinery this app avoids adding. See docs/linux/desktop.md's
    // "Light/Dark/System theme" row for the full picture.
    testWidgets('pinning HostPlatform.linux changes nothing about the result',
        (tester) async {
      setDeviceBrightness(tester, Brightness.dark);
      await pumpApp(tester, host: HostPlatform.linux);

      expect(renderedBrightness(tester), Brightness.dark);
    });

    testWidgets('pinning HostPlatform.android changes nothing about the result',
        (tester) async {
      setDeviceBrightness(tester, Brightness.light);
      await pumpApp(tester, host: HostPlatform.android);

      expect(renderedBrightness(tester), Brightness.light);
    });
  });

  group('the stored choice is applied without a flash', () {
    testWidgets('the seeded preference is live on the very first frame',
        (tester) async {
      // Seeded the way main does: read from storage before runApp. The
      // assertion is that the *first* pump already renders light on a dark
      // device — no intermediate dark frame to flash through.
      setDeviceBrightness(tester, Brightness.dark);
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          ...completedOnboardingOverrides(),
          playbackControllerProvider
              .overrideWithValue(FakePlaybackController()),
          initialThemeModeProvider.overrideWithValue(ThemeModePreference.light),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const LinthraApp(),
        ),
      );

      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.light,
        reason: 'the stored mode must be applied before the first frame, '
            'not loaded asynchronously afterwards',
      );
    });

    testWidgets('changing the mode at runtime repaints the app',
        (tester) async {
      final InMemoryThemeModeStore store = InMemoryThemeModeStore();
      setDeviceBrightness(tester, Brightness.dark);
      final ProviderContainer container = await pumpApp(tester, store: store);
      expect(renderedBrightness(tester), Brightness.dark);

      await container
          .read(themeModeControllerProvider.notifier)
          .select(ThemeModePreference.light);
      await tester.pumpAndSettle();

      expect(renderedBrightness(tester), Brightness.light);
      expect(store.preference, ThemeModePreference.light);
    });
  });
}
