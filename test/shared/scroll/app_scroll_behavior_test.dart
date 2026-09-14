import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/brand_theme.dart';
import 'package:linthra/app/linthra_app.dart';
import 'package:linthra/app/theme.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/shared/scroll/app_scroll_behavior.dart';

import '../../features/player/fake_playback_controller.dart';
import '../../support/onboarding_test_overrides.dart';

/// The app's one scroll policy (#396).
///
/// It is the only place in Linthra where a scrolling decision names a
/// platform, which is the point: without it, "stop this list bouncing like a
/// phone" is a check somebody has to remember to paste into every list, grid,
/// sheet and dialog in the app.

/// The physics and decoration a scrollable actually resolves under [platform],
/// read through the same `ScrollConfiguration` the app installs.
Future<({ScrollPhysics physics, bool hasOverscrollIndicator})> _resolve(
  WidgetTester tester,
  TargetPlatform platform,
) async {
  late ScrollPhysics physics;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark(BrandPalettes.classic).copyWith(platform: platform),
      scrollBehavior: const AppScrollBehavior(),
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) {
            physics = ScrollConfiguration.of(context).getScrollPhysics(context);
            return ListView.builder(
              itemCount: 60,
              itemBuilder: (BuildContext context, int index) =>
                  SizedBox(height: 40, child: Text('row $index')),
            );
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (
    physics: physics,
    hasOverscrollIndicator:
        find.byType(GlowingOverscrollIndicator).evaluate().isNotEmpty ||
            find.byType(StretchingOverscrollIndicator).evaluate().isNotEmpty,
  );
}

void main() {
  testWidgets('a desktop list stops dead at its ends', (tester) async {
    final result = await _resolve(tester, TargetPlatform.linux);
    expect(result.physics, isA<ClampingScrollPhysics>());
    expect(
      result.physics,
      isNot(isA<BouncingScrollPhysics>()),
      reason: 'a Linux window must not rubber-band like a phone',
    );
  });

  testWidgets('and still keeps its offset when the content shrinks',
      (tester) async {
    // Material composes its clamping default over RangeMaintainingScrollPhysics,
    // which is what holds a list's offset steady when content is removed or the
    // window is resized. Naming the physics without its parent would drop that
    // everywhere — a jump on resize rather than a desktop improvement.
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.linux,
      TargetPlatform.android,
    ]) {
      final result = await _resolve(tester, platform);
      expect(
        result.physics.parent,
        isA<RangeMaintainingScrollPhysics>(),
        reason: 'clamping physics on $platform lost its range-maintaining '
            'parent',
      );
    }
  });

  testWidgets('Android resolves exactly the physics Material would give it',
      (tester) async {
    // The whole promise of this behaviour off desktop: a phone is unchanged.
    late ScrollPhysics material;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Builder(
          builder: (BuildContext context) {
            material = const MaterialScrollBehavior().getScrollPhysics(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final result = await _resolve(tester, TargetPlatform.android);
    expect(result.physics.toString(), material.toString());
  });

  testWidgets('a desktop list draws no overscroll glow or stretch',
      (tester) async {
    final result = await _resolve(tester, TargetPlatform.linux);
    expect(result.hasOverscrollIndicator, isFalse);
  });

  testWidgets('Android keeps the physics and the overscroll it always had',
      (tester) async {
    final result = await _resolve(tester, TargetPlatform.android);
    expect(result.physics, isA<ClampingScrollPhysics>());
    expect(
      result.hasOverscrollIndicator,
      isTrue,
      reason: 'the stretch is what a thumb expects at the end of a list',
    );
  });

  testWidgets('Apple platforms keep their own rubber band', (tester) async {
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    ]) {
      final result = await _resolve(tester, platform);
      expect(
        result.physics,
        isA<BouncingScrollPhysics>(),
        reason: 'bouncing is native on $platform, not a mobile import',
      );
    }
  });

  test('a mouse is not a drag device', () {
    // Press-and-move with a mouse means selecting, rubber-banding or dragging
    // a row to a playlist. A list that scrolled out from under that would make
    // all three unusable — a mouse scrolls with its wheel.
    expect(
      const AppScrollBehavior().dragDevices,
      isNot(contains(PointerDeviceKind.mouse)),
    );
  });

  test('everything finger-like still drags, trackpads included', () {
    expect(
      const AppScrollBehavior().dragDevices,
      containsAll(<PointerDeviceKind>[
        PointerDeviceKind.touch,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
        // What turns a two-finger pan into one smooth drag rather than a
        // stream of jumps.
        PointerDeviceKind.trackpad,
        // What accessibility services send.
        PointerDeviceKind.unknown,
      ]),
    );
  });

  testWidgets('the app installs the policy itself', (tester) async {
    // Pumping the whole app is the only way to prove the seam is actually
    // wired up: a behaviour nothing installs protects nothing.
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...completedOnboardingOverrides(),
          playbackControllerProvider
              .overrideWithValue(FakePlaybackController()),
        ],
        child: const LinthraApp(),
      ),
    );
    await tester.pumpAndSettle();
    final Iterable<MaterialApp> apps =
        tester.widgetList<MaterialApp>(find.byType(MaterialApp));
    expect(apps, isNotEmpty);
    for (final MaterialApp app in apps) {
      expect(app.scrollBehavior, isA<AppScrollBehavior>());
    }
  });
}
